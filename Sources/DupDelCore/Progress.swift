import Foundation

/// 处理阶段，同时决定总进度条上的权重区间。
public enum Phase: String, Sendable, CaseIterable, Equatable {
    case idle
    case scanning
    case groupingBySize
    case partialHashing
    case fullHashing
    case completed
    case cleaning
    case cancelled
    case failed

    public var base: Double {
        switch self {
        case .idle: return 0
        case .scanning: return 0.02
        case .groupingBySize: return 0.45
        case .partialHashing: return 0.50
        case .fullHashing: return 0.75
        case .completed: return 1
        case .cleaning: return 0
        case .cancelled, .failed: return 0
        }
    }

    public var span: Double {
        switch self {
        case .scanning: return 0.43
        case .groupingBySize: return 0.05
        case .partialHashing: return 0.25
        case .fullHashing: return 0.23
        case .completed: return 0
        case .cleaning: return 1
        case .idle, .cancelled, .failed: return 0
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed: return true
        default: return false
        }
    }
}

public struct ProgressUpdate: Sendable, Equatable {
    public let phase: Phase
    public let processed: Int
    public let total: Int
    public let detail: String

    public init(phase: Phase, processed: Int = 0, total: Int = 0, detail: String = "") {
        self.phase = phase
        self.processed = processed
        self.total = total
        self.detail = detail
    }

    /// 当前阶段内部进度；total 为 0 时表示不确定进度。
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Swift.min(1, Swift.max(0, Double(processed) / Double(total)))
    }

    /// 跨阶段的总体进度（0~1）。
    public var overall: Double {
        if phase == .completed { return 1 }
        return phase.base + phase.span * fraction
    }
}

/// 高频进度回调的节流器：海量文件下避免每秒上千次 UI 刷新导致卡顿。
public final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private let emit: @Sendable (ProgressUpdate) -> Void
    private var lastEmit: Date = .distantPast

    public init(interval: TimeInterval = 0.12, emit: @escaping @Sendable (ProgressUpdate) -> Void) {
        self.interval = interval
        self.emit = emit
    }

    public func report(_ update: ProgressUpdate, force: Bool = false) {
        let now = Date()
        lock.lock()
        let shouldEmit = force || now.timeIntervalSince(lastEmit) >= interval
        if shouldEmit { lastEmit = now }
        lock.unlock()
        if shouldEmit { emit(update) }
    }
}
