import Foundation

/// 目录树中的一个普通文件。
public struct FileEntry: Sendable, Hashable, Identifiable {
    public let url: URL
    public let size: UInt64
    public let modified: Date
    public let created: Date

    public init(url: URL, size: UInt64, modified: Date, created: Date) {
        self.url = url
        self.size = size
        self.modified = modified
        self.created = created
    }

    public var id: URL { url }
    public var path: String { url.path }

    /// 「创建或修改日期」中较新的那个，用于决定保留哪一份副本。
    public var recency: Date { modified >= created ? modified : created }
}

/// 保留策略。需求要求保留「创建或修改日期最新」的副本。
public enum KeepPolicy: String, Sendable, CaseIterable, Equatable {
    case newest
    case oldest
}

/// 一组内容完全相同的文件。
public struct DuplicateGroup: Sendable, Identifiable, Equatable {
    public let hash: String
    public let fileSize: UInt64
    public let files: [FileEntry]
    public let keeperIndex: Int
    /// 冗余副本数量（缓存，避免 UI 频繁遍历数组）。
    public let redundantCount: Int

    public init(hash: String, files: [FileEntry], policy: KeepPolicy = .newest) {
        precondition(!files.isEmpty, "DuplicateGroup 至少需要 1 个文件")
        self.hash = hash
        self.files = files
        self.fileSize = files.first?.size ?? 0
        self.keeperIndex = Self.resolveKeeper(files: files, policy: policy)
        self.redundantCount = files.count - 1
    }

    public var id: String { hash }
    public var keeper: FileEntry { files[keeperIndex] }
    public var redundant: [FileEntry] { files.enumerated().filter { $0.offset != keeperIndex }.map { $0.element } }
    public var reclaimableBytes: UInt64 { fileSize * UInt64(Swift.max(0, files.count - 1)) }

    /// 保留规则：日期最新（或最旧）；日期相同时按路径字典序，保证结果稳定可复现。
    public static func resolveKeeper(files: [FileEntry], policy: KeepPolicy) -> Int {
        guard !files.isEmpty else { return 0 }
        var best = 0
        for i in 1..<files.count where isBetter(files[i], than: files[best], policy: policy) {
            best = i
        }
        return best
    }

    public static func isBetter(_ lhs: FileEntry, than rhs: FileEntry, policy: KeepPolicy) -> Bool {
        if lhs.recency != rhs.recency {
            return policy == .newest ? lhs.recency > rhs.recency : lhs.recency < rhs.recency
        }
        return lhs.path < rhs.path
    }
}

/// 处理过程中无法读取 / 无法删除的条目。
public struct FileIssue: Sendable, Equatable {
    public let url: URL
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

public enum DedupError: Error, LocalizedError, Sendable, Equatable {
    case notADirectory(URL)
    case readFailed(URL, String)
    case deleteFailed(URL, String)
    case rootNotSelected

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let url):
            return "路径不是目录或不可访问：\(url.path)"
        case .readFailed(let url, let reason):
            return "读取失败: \(url.path) (\(reason))"
        case .deleteFailed(let url, let reason):
            return "删除失败: \(url.path) (\(reason))"
        case .rootNotSelected:
            return "请先选择要分析的目录"
        }
    }
}
