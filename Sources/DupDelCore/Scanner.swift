import Foundation

public struct ScanOptions: Sendable, Equatable {
    /// 是否包含隐藏文件（默认跳过，避免扫描 .git 之类目录）。
    public var includeHiddenFiles: Bool = false
    /// 是否忽略 0 字节文件（默认忽略，避免误删 .gitkeep 之类占位文件）。
    public var skipZeroLengthFiles: Bool = true
    /// 小于该体积的文件不参与排重（字节）。
    public var minimumFileSize: UInt64 = 0
    /// 快速校验（部分哈希）读取的字节数。
    public var partialHashBytes: Int = 64 * 1024
    /// 哈希并发数，0 表示按 CPU 核数自动决定。
    public var maxHashingConcurrency: Int = 0
    /// 读文件缓冲区大小。
    public var readBufferBytes: Int = 1 << 20

    public init() {}

    public var directoryEnumerationOptions: FileManager.DirectoryEnumerationOptions {
        includeHiddenFiles ? [] : [.skipsHiddenFiles]
    }

    /// 自动并发度：I/O 与 CPU 混合型负载，取 2~8 之间，避免磁盘抖动与内存峰值。
    public var resolvedConcurrency: Int {
        guard maxHashingConcurrency <= 0 else { return maxHashingConcurrency }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return Swift.min(8, Swift.max(2, cores))
    }
}

public struct ScanOutcome: Sendable {
    public var totalFiles: Int = 0
    public var totalBytes: UInt64 = 0
    public var skippedFiles: Int = 0
    public var inaccessibleDirectories: [URL] = []
    /// 仅保留「同体积文件数 ≥ 2」的分组，唯一体积直接丢弃以节省内存。
    public var buckets: [UInt64: [FileEntry]] = [:]

    public init() {}
}

/// 迭代式深度优先遍历（非递归，避免深层目录栈溢出），
/// 一次遍历同时完成：文件计数、体积统计、按体积分桶。
public struct FileScanner: Sendable {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
    ]

    /// 预转换好的数组，避免每个目录都重新构造一次（海量目录时的无谓开销）。
    private static let resourceKeyList: [URLResourceKey] = Array(resourceKeys)

    public init() {}

    public func scan(
        root: URL,
        options: ScanOptions = ScanOptions(),
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (Int, UInt64) -> Void = { _, _ in }
    ) throws -> ScanOutcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DedupError.notADirectory(root)
        }

        let bucketStore = BucketStore()
        var outcome = ScanOutcome()
        var stack: [URL] = [root.standardizedFileURL]
        var sinceLastReport = 0

        while let directory = stack.popLast() {
            if isCancelled() { throw CancellationError() }

            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Self.resourceKeyList,
                    options: options.directoryEnumerationOptions
                )
            } catch {
                if outcome.inaccessibleDirectories.count < 32 {
                    outcome.inaccessibleDirectories.append(directory)
                }
                continue
            }

            for child in children {
                if isCancelled() { throw CancellationError() }

                let values = try? child.resourceValues(forKeys: Self.resourceKeys)
                if values?.isSymbolicLink == true {
                    outcome.skippedFiles += 1
                    continue
                }
                if values?.isDirectory == true {
                    stack.append(child)
                    continue
                }
                guard values?.isRegularFile == true else {
                    outcome.skippedFiles += 1
                    continue
                }

                let size = UInt64(values?.fileSize ?? 0)
                if options.skipZeroLengthFiles && size == 0 {
                    outcome.skippedFiles += 1
                    continue
                }
                if size < options.minimumFileSize {
                    outcome.skippedFiles += 1
                    continue
                }

                let entry = FileEntry(
                    url: child,
                    size: size,
                    modified: values?.contentModificationDate ?? Date.distantPast,
                    created: values?.creationDate ?? Date.distantPast
                )
                bucketStore.append(entry)
                outcome.totalFiles += 1
                outcome.totalBytes += size

                sinceLastReport += 1
                if sinceLastReport >= 500 {
                    sinceLastReport = 0
                    onProgress(outcome.totalFiles, outcome.totalBytes)
                }
            }
        }

        onProgress(outcome.totalFiles, outcome.totalBytes)
        outcome.buckets = bucketStore.duplicatedBuckets()
        return outcome
    }
}

/// 分桶容器：使用引用类型避免数组写时复制带来的重复内存拷贝。
private final class BucketStore: @unchecked Sendable {
    private final class Bucket {
        var entries: [FileEntry] = []
    }

    private var buckets: [UInt64: Bucket] = [:]

    func append(_ entry: FileEntry) {
        let bucket: Bucket
        if let existing = buckets[entry.size] {
            bucket = existing
        } else {
            bucket = Bucket()
            buckets[entry.size] = bucket
        }
        bucket.entries.append(entry)
    }

    /// 只交出「同体积 ≥ 2」的分组，其余立即释放，降低峰值内存。
    func duplicatedBuckets() -> [UInt64: [FileEntry]] {
        var result: [UInt64: [FileEntry]] = [:]
        result.reserveCapacity(Swift.min(buckets.count, 4_096))
        for (size, bucket) in buckets where bucket.entries.count > 1 {
            result[size] = bucket.entries
            bucket.entries.removeAll(keepingCapacity: false)
        }
        buckets.removeAll(keepingCapacity: false)
        return result
    }
}
