import Darwin
import Foundation

public struct CleanOptions: Sendable, Equatable {
    /// 删除前先移到废纸篓（更安全，但大量文件时更慢）。
    public var useTrash: Bool = false
    /// 删除后如果目录变空，则一并删除该目录（含级联向上）。
    public var pruneEmptyDirectories: Bool = true
    /// 演练模式：只统计不实际删除。
    public var dryRun: Bool = false
    /// 删除前重新读取文件并复核「体积 + 内容哈希」是否与所属组一致。
    /// 代价是冗余副本会被再读一遍；换来的是：分析之后发生变化的文件不会被删掉。
    public var verifyBeforeDeleting: Bool = true

    public init() {}
}

public struct CleanResult: Sendable, Equatable {
    public var deletedFiles: Int = 0
    public var reclaimedBytes: UInt64 = 0
    public var prunedDirectories: Int = 0
    /// 分析后已被外部删除的文件数量，跳过即可，不算失败。
    public var missingFiles: Int = 0
    /// 删除失败的总数（可能大于 failures 的条数，后者只保留前若干条明细）。
    public var failedFiles: Int = 0
    /// 删除前复核未通过而被安全跳过的文件数（内容已与分析时不同）。
    public var unverifiedFiles: Int = 0
    public var failures: [FileIssue] = []

    public init() {}

    /// failures 明细最多保留的条数，避免海量失败撑爆内存。
    public static let maxRecordedFailures = 256
}

/// 重复文件清理器：删除每组的冗余副本（保留日期最新的一份），并回收空目录。
public struct Cleaner: Sendable {
    public init() {}

    public func clean(
        groups: [DuplicateGroup],
        root: URL,
        options: CleanOptions = CleanOptions(),
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (Int, Int, String) -> Void = { _, _, _ in }
    ) -> CleanResult {
        let rootPath = Self.canonicalPath(root)
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        var result = CleanResult()
        var targets: [(group: DuplicateGroup, entry: FileEntry)] = []
        for group in groups {
            for entry in group.redundant {
                // 安全护栏：绝不删除根目录之外的文件。
                guard Self.canonicalPath(entry.url).hasPrefix(rootPrefix) else { continue }
                targets.append((group, entry))
            }
        }

        let total = targets.count
        var affectedDirectories: Set<URL> = []

        for (index, target) in targets.enumerated() {
            if isCancelled() { break }
            let entry = target.entry
            onProgress(index, total, entry.url.path)

            if options.dryRun {
                result.deletedFiles += 1
                result.reclaimedBytes += entry.size
                affectedDirectories.insert(entry.url.deletingLastPathComponent())
                continue
            }

            if !FileManager.default.fileExists(atPath: entry.url.path) {
                // 分析之后被外部删除：跳过，不计入失败
                result.missingFiles += 1
                continue
            }

            // 删除前的最后一道护栏：重新读取这份副本，确认它的体积与内容哈希
            // 仍然与所属组完全一致。分析之后内容发生变化的文件一律不删。
            if options.verifyBeforeDeleting && !Self.matchesGroup(entry: entry, group: target.group) {
                result.unverifiedFiles += 1
                continue
            }

            do {
                if options.useTrash {
                    try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
                } else {
                    try FileManager.default.removeItem(at: entry.url)
                }
                result.deletedFiles += 1
                result.reclaimedBytes += entry.size
                affectedDirectories.insert(entry.url.deletingLastPathComponent())
            } catch {
                result.failedFiles += 1
                if result.failures.count < CleanResult.maxRecordedFailures {
                    result.failures.append(FileIssue(url: entry.url, reason: error.localizedDescription))
                }
            }
        }

        onProgress(total, total, "清理完成")

        if options.pruneEmptyDirectories && !options.dryRun {
            result.prunedDirectories = prune(affectedDirectories, rootPath: rootPath, rootPrefix: rootPrefix)
        }
        return result
    }

    /// 复核某份冗余副本是否仍然与所属组完全一致（体积 + 内容哈希）。
    private static func matchesGroup(entry: FileEntry, group: DuplicateGroup) -> Bool {
        guard let current = FileHasher.fileStat(url: entry.url), current.size == entry.size else { return false }
        guard let hash = try? FileHasher.hash(url: entry.url) else { return false }
        return hash == group.contentHash
    }

    /// 自底向上删除空目录；根目录本身不会被删除。
    private func prune(_ directories: Set<URL>, rootPath: String, rootPrefix: String) -> Int {
        var visited: Set<String> = []
        var pruned = 0

        let sorted = directories
            .map { Self.canonicalPath($0) }
            .sorted { $0.count > $1.count }

        for path in sorted {
            var currentPath = path
            while currentPath != rootPath, currentPath.hasPrefix(rootPrefix) {
                guard visited.insert(currentPath).inserted else { break }
                guard isEmptyDirectory(atPath: currentPath) else { break }
                do {
                    try FileManager.default.removeItem(atPath: currentPath)
                    pruned += 1
                } catch {
                    break
                }
                currentPath = Self.canonicalPath(URL(fileURLWithPath: currentPath).deletingLastPathComponent())
            }
        }
        return pruned
    }

    /// 真实路径（realpath）。
    /// 注意：不能用 standardizedFileURL —— 它会把 /private/var 折叠成 /var，
    /// 与 FileManager 枚举得到的真实路径方向相反，会导致前缀判断失效。
    private static func canonicalPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let resolved = url.path.withCString { source in
            realpath(source, &buffer)
        }
        if resolved != nil { return String(cString: buffer) }
        return url.path
    }

    private func isEmptyDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path).isEmpty
        } catch {
            return false
        }
    }
}
