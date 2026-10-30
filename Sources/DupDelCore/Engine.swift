import Foundation

public struct AnalysisResult: Sendable, Equatable {
    public let root: URL
    public let totalFiles: Int
    public let totalBytes: UInt64
    public let groups: [DuplicateGroup]
    public let skippedFiles: Int
    public let inaccessibleDirectories: [URL]
    public let unreadableFiles: [FileIssue]
    public let duration: TimeInterval

    public init(
        root: URL,
        totalFiles: Int,
        totalBytes: UInt64,
        groups: [DuplicateGroup],
        skippedFiles: Int = 0,
        inaccessibleDirectories: [URL] = [],
        unreadableFiles: [FileIssue] = [],
        duration: TimeInterval = 0
    ) {
        self.root = root
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
        self.groups = groups
        self.skippedFiles = skippedFiles
        self.inaccessibleDirectories = inaccessibleDirectories
        self.unreadableFiles = unreadableFiles
        self.duration = duration
    }

    public var duplicateGroupCount: Int { groups.count }
    public var redundantFileCount: Int { groups.reduce(0) { $0 + $1.redundantCount } }
    public var reclaimableBytes: UInt64 { groups.reduce(0) { $0 + $1.reclaimableBytes } }
    /// 预估清理后的文件数量。
    public var filesAfterCleanup: Int { Swift.max(0, totalFiles - redundantFileCount) }
    /// 预估清理后的总占用空间。
    public var bytesAfterCleanup: UInt64 { totalBytes > reclaimableBytes ? totalBytes - reclaimableBytes : 0 }
}

/// 分组键：体积 + 是否为完整哈希 + 哈希值。
/// 必须带体积：不同体积的文件可能拥有相同的前 N 字节哈希。
private struct GroupKey: Hashable {
    let size: UInt64
    let isFull: Bool
    let hash: String
}

private struct HashPhaseResult: Sendable {
    /// 与 entries 一一对应的哈希结果，nil 表示读取失败或被取消。
    let hashes: [String?]
    /// 与 entries 一一对应的文件属性快照，nil 表示未读取成功。
    let stats: [FileStat?]
    let failures: [FileIssue]
}

/// 全局排重引擎：扫描 → 按体积分桶 → 快速部分哈希 → 完整哈希 → 分组。
/// 所有重活都在后台队列执行，进度回调经过节流。
public final class DedupEngine: Sendable {
    public init() {}

    public func analyse(
        root: URL,
        options: ScanOptions = ScanOptions(),
        progress: @escaping @Sendable (ProgressUpdate) -> Void = { _ in }
    ) async throws -> AnalysisResult {
        let started = Date()
        let flag = CancelFlag()
        let reporter = ProgressReporter(emit: progress)
        let scanner = FileScanner()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            reporter.report(ProgressUpdate(phase: .scanning, detail: "开始扫描：\(root.path)"), force: true)

            let outcome = try await Background.run {
                try scanner.scan(
                    root: root,
                    options: options,
                    isCancelled: { flag.isCancelled }
                ) { count, bytes in
                    reporter.report(
                        ProgressUpdate(
                            phase: .scanning,
                            processed: count,
                            detail: "已扫描 \(ByteFormatter.count(count)) 个文件 · \(ByteFormatter.string(bytes))"
                        )
                    )
                }
            }

            try Task.checkCancellation()
            if !outcome.inaccessibleDirectories.isEmpty {
                reporter.report(
                    ProgressUpdate(phase: .scanning, detail: "跳过 \(outcome.inaccessibleDirectories.count) 个无权限目录"),
                    force: true
                )
            }

            reporter.report(
                ProgressUpdate(phase: .groupingBySize, processed: 1, total: 1, detail: "按文件体积分桶…"),
                force: true
            )

            var unreadable: [FileIssue] = []
            let candidates: [FileEntry] = outcome.buckets.values.flatMap { $0 }
            let concurrency = options.resolvedConcurrency
            // 下限保护：partialHashBytes 为 0 会让所有文件哈希成「空内容」，造成误判
            let partialBytes = UInt64(Swift.max(4_096, options.partialHashBytes))
            let bufferSize = options.readBufferBytes

            guard !candidates.isEmpty else {
                reporter.report(ProgressUpdate(phase: .completed, processed: 1, total: 1, detail: "未发现重复文件"), force: true)
                return AnalysisResult(
                    root: root,
                    totalFiles: outcome.totalFiles,
                    totalBytes: outcome.totalBytes,
                    groups: [],
                    skippedFiles: outcome.skippedFiles,
                    inaccessibleDirectories: outcome.inaccessibleDirectories,
                    duration: Date().timeIntervalSince(started)
                )
            }

            // 阶段一：只哈希前 N 字节，用极小 I/O 成本淘汰绝大部分非重复文件。
            reporter.report(
                ProgressUpdate(phase: .partialHashing, processed: 0, total: candidates.count, detail: "快速校验 \(ByteFormatter.count(candidates.count)) 个候选文件…"),
                force: true
            )
            let partial = try await Background.run {
                Self.hashPhase(
                    entries: candidates,
                    full: false,
                    partialBytes: partialBytes,
                    bufferSize: bufferSize,
                    concurrency: concurrency,
                    isCancelled: { flag.isCancelled }
                ) { done in
                    reporter.report(
                        ProgressUpdate(
                            phase: .partialHashing,
                            processed: done,
                            total: candidates.count,
                            detail: "快速校验 \(ByteFormatter.count(done))/\(ByteFormatter.count(candidates.count))"
                        )
                    )
                }
            }
            Self.appendIssues(partial.failures, to: &unreadable)

            try Task.checkCancellation()

            // 每个候选文件在哈希时刻的属性快照；分组阶段用下标寻址，避免再维护一份字典
            var candidateStats: [FileStat?] = Array(repeating: nil, count: candidates.count)
            for (index, stat) in partial.stats.enumerated() { candidateStats[index] = stat }

            var partialGroups: [GroupKey: [Int]] = [:]
            for (index, entry) in candidates.enumerated() {
                guard let hash = partial.hashes[index] else { continue }
                let key = GroupKey(size: entry.size, isFull: entry.size <= partialBytes, hash: hash)
                partialGroups[key, default: []].append(index)
            }

            var finalGroups: [GroupKey: [Int]] = [:]
            var needFullHash: [Int] = []
            for (key, indices) in partialGroups where indices.count > 1 {
                if key.isFull {
                    finalGroups[key] = indices
                } else {
                    needFullHash.append(contentsOf: indices)
                }
            }

            // 阶段二：仅对部分哈希冲突的文件做完整哈希。
            let fullCandidateIndices = needFullHash
            let fullCandidates = fullCandidateIndices.map { candidates[$0] }
            if !fullCandidates.isEmpty {
                reporter.report(
                    ProgressUpdate(phase: .fullHashing, processed: 0, total: fullCandidates.count, detail: "完整校验 \(ByteFormatter.count(fullCandidates.count)) 个文件…"),
                    force: true
                )
                let full = try await Background.run {
                    Self.hashPhase(
                        entries: fullCandidates,
                        full: true,
                        partialBytes: partialBytes,
                        bufferSize: bufferSize,
                        concurrency: concurrency,
                        isCancelled: { flag.isCancelled }
                    ) { done in
                        reporter.report(
                            ProgressUpdate(
                                phase: .fullHashing,
                                processed: done,
                                total: fullCandidates.count,
                                detail: "完整校验 \(ByteFormatter.count(done))/\(ByteFormatter.count(fullCandidates.count))"
                            )
                        )
                    }
                }
                Self.appendIssues(full.failures, to: &unreadable)
                for (offset, candidateIndex) in fullCandidateIndices.enumerated() {
                    guard let hash = full.hashes[offset] else { continue }
                    candidateStats[candidateIndex] = full.stats[offset]
                    let entry = candidates[candidateIndex]
                    let key = GroupKey(size: entry.size, isFull: true, hash: hash)
                    finalGroups[key, default: []].append(candidateIndex)
                }
            }

            try Task.checkCancellation()

            let groups = finalGroups
                .compactMap { key, indices -> DuplicateGroup? in
                    let members = Self.membersOf(candidates: candidates, indices: indices, stats: candidateStats)
                    guard members.count > 1 else { return nil }
                    return DuplicateGroup(hash: "\(key.size)-\(key.hash)", files: members, policy: .newest)
                }
                .sorted { lhs, rhs in
                    if lhs.reclaimableBytes != rhs.reclaimableBytes { return lhs.reclaimableBytes > rhs.reclaimableBytes }
                    return lhs.keeper.path < rhs.keeper.path
                }

            let result = AnalysisResult(
                root: root,
                totalFiles: outcome.totalFiles,
                totalBytes: outcome.totalBytes,
                groups: groups,
                skippedFiles: outcome.skippedFiles,
                inaccessibleDirectories: outcome.inaccessibleDirectories,
                unreadableFiles: unreadable,
                duration: Date().timeIntervalSince(started)
            )
            reporter.report(
                ProgressUpdate(
                    phase: .completed,
                    processed: 1,
                    total: 1,
                    detail: "分析完成：\(ByteFormatter.count(result.duplicateGroupCount)) 组重复，可回收 \(ByteFormatter.string(result.reclaimableBytes))"
                ),
                force: true
            )
            return result
        } onCancel: {
            flag.cancel()
        }
    }

    /// 把某一组的候选下标还原成文件列表（按路径升序），并剔除其中的硬链接重复项。
    ///
    /// 同一 inode 的多个目录项（硬链接）指向同一份数据：删除其中一份不会释放任何空间，
    /// 因此它们不构成「可回收的重复」。组内每个 inode 只保留一个代表，
    /// 若剔重后不足两份则调用方不会成组。
    private static func membersOf(
        candidates: [FileEntry],
        indices: [Int],
        stats: [FileStat?]
    ) -> [FileEntry] {
        let sorted = indices.sorted { candidates[$0].path < candidates[$1].path }
        var seenIdentities: Set<FileIdentity> = []
        var members: [FileEntry] = []
        for index in sorted {
            if let identity = stats[index]?.identity, seenIdentities.insert(identity).inserted == false {
                continue
            }
            members.append(candidates[index])
        }
        return members
    }

    /// 只保留前 maxRecordedIssues 条异常，避免极端场景下内存膨胀。
    private static let maxRecordedIssues = 64

    private static func appendIssues(_ issues: [FileIssue], to storage: inout [FileIssue]) {
        guard storage.count < maxRecordedIssues else { return }
        storage.append(contentsOf: issues.prefix(maxRecordedIssues - storage.count))
    }

    private static func hashPhase(
        entries: [FileEntry],
        full: Bool,
        partialBytes: UInt64,
        bufferSize: Int,
        concurrency: Int,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Int) -> Void
    ) -> HashPhaseResult {
        let outcome = Parallel.map(
            entries,
            maxConcurrency: concurrency,
            isCancelled: isCancelled,
            progress: progress
        ) { entry -> (String, FileStat) in
            // 体积稳定性校验：扫描阶段记录的体积必须与哈希时一致。
            // 文件在分析过程中被增删/截断时，旧体积会让「size ≤ partialBytes」的
            // 快捷判定失效（部分哈希被当成整文件哈希），也会让组内成员真实体积不一致。
            guard let before = FileHasher.fileStat(url: entry.url) else {
                throw DedupError.readFailed(entry.url, "无法读取文件属性")
            }
            guard before.size == entry.size else {
                throw DedupError.readFailed(
                    entry.url,
                    "文件在分析期间发生变化（记录 \(entry.size) 字节，当前 \(before.size) 字节）"
                )
            }
            let limit: Int? = full ? nil : (entry.size <= partialBytes ? nil : Int(partialBytes))
            let hash = try FileHasher.hash(url: entry.url, maxBytes: limit, bufferSize: bufferSize)
            // 读取期间若被改写，哈希结果不可信，直接丢弃这次结果。
            guard let after = FileHasher.fileStat(url: entry.url), after.size == before.size else {
                throw DedupError.readFailed(entry.url, "读取过程中文件被修改，结果已废弃")
            }
            return (hash, before)
        }

        let failures = outcome.failures.map { FileIssue(url: entries[$0.index].url, reason: $0.reason) }
        let hashes = outcome.results.map { $0?.0 }
        let stats = outcome.results.map { $0?.1 }
        return HashPhaseResult(hashes: hashes, stats: stats, failures: failures)
    }
}
