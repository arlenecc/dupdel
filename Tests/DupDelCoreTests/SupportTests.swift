import Foundation
import Testing
@testable import DupDelCore

@Suite struct SupportTests {
    @Test func progressReporterThrottles() {
        let counter = Counter()
        let reporter = ProgressReporter(interval: 0.5) { _ in counter.increment() }
        let update = ProgressUpdate(phase: .scanning, processed: 1, total: 2)

        for _ in 0..<20 { reporter.report(update) }

        #expect(counter.value == 1)
    }

    @Test func progressReporterForceAlwaysEmits() {
        let counter = Counter()
        let reporter = ProgressReporter(interval: 60) { _ in counter.increment() }

        reporter.report(ProgressUpdate(phase: .scanning), force: true)
        reporter.report(ProgressUpdate(phase: .groupingBySize), force: true)

        #expect(counter.value == 2)
    }

    @Test func progressOverallFraction() {
        #expect(abs(ProgressUpdate(phase: .scanning, processed: 0, total: 100).overall - 0.02) < 0.0001)
        #expect(abs(ProgressUpdate(phase: .partialHashing, processed: 50, total: 100).overall - 0.625) < 0.0001)
        #expect(ProgressUpdate(phase: .completed).overall == 1)
        #expect(ProgressUpdate(phase: .scanning, processed: 10, total: 0).fraction == 0)
    }

    @Test func byteFormatter() {
        #expect(ByteFormatter.string(0) == "0 B")
        #expect(ByteFormatter.string(512) == "512 B")
        #expect(ByteFormatter.string(1_024) == "1.00 KB")
        #expect(ByteFormatter.string(1_536) == "1.50 KB")
        #expect(ByteFormatter.string(1_024 * 1_024) == "1.00 MB")
        #expect(ByteFormatter.string(3 * 1_024 * 1_024 * 1_024) == "3.00 GB")
        #expect(ByteFormatter.count(1_234_567) == "1,234,567")
    }

    @Test func duplicateGroupKeeperSelection() {
        let base = Date.test(secondsSince1970: 1_000)
        let newer = Date.test(secondsSince1970: 2_000)
        let files = [
            FileEntry(url: URL(fileURLWithPath: "/tmp/b.txt"), size: 10, modified: base, created: base),
            FileEntry(url: URL(fileURLWithPath: "/tmp/a.txt"), size: 10, modified: newer, created: base),
        ]

        let newestWins = DuplicateGroup(hash: "h", files: files)
        #expect(newestWins.keeper.url.lastPathComponent == "a.txt")
        #expect(newestWins.reclaimableBytes == 10)

        let oldestWins = DuplicateGroup(hash: "h", files: files, policy: .oldest)
        #expect(oldestWins.keeper.url.lastPathComponent == "b.txt")
    }

    @Test func keeperPrefersNewestOfCreationOrModification() {
        let files = [
            FileEntry(url: URL(fileURLWithPath: "/tmp/a.txt"), size: 4, modified: .test(secondsSince1970: 500_000), created: .test(secondsSince1970: 500)),
            FileEntry(url: URL(fileURLWithPath: "/tmp/b.txt"), size: 4, modified: .test(secondsSince1970: 100), created: .test(secondsSince1970: 900_000)),
        ]

        let group = DuplicateGroup(hash: "h", files: files)

        // b 的创建日期更晚，max(创建, 修改) 更大，应当保留 b
        #expect(group.keeper.url.lastPathComponent == "b.txt")
        #expect(group.redundant.count == 1)
    }

    @Test func resolvedConcurrencyIsBounded() {
        var options = ScanOptions()
        #expect(options.resolvedConcurrency == min(8, max(2, ProcessInfo.processInfo.activeProcessorCount)))
        options.maxHashingConcurrency = 3
        #expect(options.resolvedConcurrency == 3)
    }

    @Test func parallelMapHandlesFailures() {
        let outcome = Parallel.map(
            Array(0..<50),
            maxConcurrency: 4,
            transform: { value -> Int in
                if value % 5 == 0 { throw DedupError.rootNotSelected }
                return value * 2
            }
        )

        #expect(outcome.results[1] == 2)
        #expect(outcome.results[0] == nil)
        #expect(outcome.failures.count == 10)
    }

    @Test func parallelMapStopsWhenCancelled() {
        let outcome = Parallel.map(
            Array(0..<1_000),
            maxConcurrency: 4,
            isCancelled: { true },
            transform: { $0 }
        )

        #expect(outcome.results.allSatisfy { $0 == nil })
        #expect(outcome.failures.isEmpty)
    }

    @Test func parallelMapPreservesOrderUnderConcurrency() {
        let outcome = Parallel.map(
            Array(0..<2_000),
            maxConcurrency: 8,
            transform: { $0 * 3 }
        )

        for index in 0..<2_000 {
            #expect(outcome.results[index] == index * 3)
        }
        #expect(outcome.failures.isEmpty)
    }
}
