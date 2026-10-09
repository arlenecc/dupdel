import Foundation

/// 可在后台线程之间安全共享的取消标记。
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// 把阻塞式（同步磁盘 I/O / CPU 密集）工作搬到 GCD 后台队列，
/// 避免占用 Swift 并发协作线程池导致 UI 及其他任务卡顿。
public enum Background {
    public static func run<T: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: qos).async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public struct ParallelFailure: Sendable, Equatable {
    public let index: Int
    public let reason: String

    public init(index: Int, reason: String) {
        self.index = index
        self.reason = reason
    }
}

public struct ParallelOutcome<R: Sendable>: Sendable {
    public var results: [R?]
    public var failures: [ParallelFailure]

    public init(results: [R?], failures: [ParallelFailure] = []) {
        self.results = results
        self.failures = failures
    }
}

/// 受限并发的并行映射：分块派发，避免海量文件下产生海量任务；
/// 单个条目失败不影响整体，仅记录原因。
public enum Parallel {
    /// 单个批次最多记录的失败数量，避免海量失败条目撑爆内存。
    public static let maxRecordedFailures = 512

    public static func map<T: Sendable, R: Sendable>(
        _ items: [T],
        maxConcurrency: Int,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: (@Sendable (Int) -> Void)? = nil,
        transform: @escaping @Sendable (T) throws -> R
    ) -> ParallelOutcome<R> {
        let count = items.count
        guard count > 0 else { return ParallelOutcome<R>(results: []) }

        let workers = Swift.max(1, maxConcurrency)
        // 每个派发块处理若干条目：既保证并发度，又降低 GCD 派发开销。
        let chunkSize = Swift.max(1, Swift.min(256, (count + workers * 4 - 1) / (workers * 4)))
        let chunkCount = (count + chunkSize - 1) / chunkSize

        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: workers)
        let state = ParallelState<R>(count: count)

        for chunkIndex in 0..<chunkCount {
            if isCancelled() { break }
            semaphore.wait()
            group.enter()
            let start = chunkIndex * chunkSize
            let end = Swift.min(count, start + chunkSize)
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    group.leave()
                    semaphore.signal()
                }
                var localResults: [Int: R] = [:]
                var localFailures: [ParallelFailure] = []
                var processed = 0
                for i in start..<end {
                    // 逐条检查取消：大文件哈希时也能及时停下来
                    if isCancelled() { break }
                    do {
                        localResults[i] = try transform(items[i])
                    } catch {
                        if localFailures.count < Self.maxRecordedFailures {
                            localFailures.append(ParallelFailure(index: i, reason: String(describing: error)))
                        }
                    }
                    processed += 1
                }
                let done = state.merge(localResults, failures: localFailures, processed: processed)
                progress?(done)
            }
        }
        group.wait()
        return state.snapshot()
    }
}

private final class ParallelState<R: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var merged: [R?]
    private var failures: [ParallelFailure] = []
    private var completed = 0

    init(count: Int) {
        merged = Array(repeating: nil, count: count)
    }

    func merge(_ chunk: [Int: R], failures chunkFailures: [ParallelFailure], processed: Int) -> Int {
        lock.lock()
        for (index, value) in chunk { merged[index] = value }
        let room = Parallel.maxRecordedFailures - failures.count
        if room > 0 {
            failures.append(contentsOf: chunkFailures.prefix(room))
        }
        completed += processed
        let done = completed
        lock.unlock()
        return done
    }

    func snapshot() -> ParallelOutcome<R> {
        lock.lock()
        defer { lock.unlock() }
        return ParallelOutcome<R>(results: merged, failures: failures)
    }
}
