import Foundation
import Testing
@testable import DupDelCore

@Suite struct EngineTests {
    private let engine = DedupEngine()

    @Test func globalDeduplicationAcrossSubdirectories() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("same-payload", to: "a/1.txt")
        try temp.write("same-payload", to: "b/2.txt")
        try temp.write("same-payload", to: "b/nested/3.txt")
        try temp.write("other", to: "c/4.txt")

        let result = try await engine.analyse(root: temp.url)

        #expect(result.totalFiles == 4)
        #expect(result.duplicateGroupCount == 1)
        let group = try #require(result.groups.first)
        #expect(group.files.count == 3)
        #expect(Set(group.files.map(\.url.lastPathComponent)) == ["1.txt", "2.txt", "3.txt"])
    }

    @Test func sameNameDifferentContentIsNotDuplicate() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("alpha", to: "a/same.txt")
        try temp.write("beta", to: "b/same.txt")

        let result = try await engine.analyse(root: temp.url)

        #expect(result.totalFiles == 2)
        #expect(result.groups.isEmpty)
    }

    @Test func uniqueFilesProduceNoGroups() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        for index in 0..<10 {
            try temp.write("unique-\(index)", to: "dir/file-\(index).txt")
        }

        let result = try await engine.analyse(root: temp.url)

        #expect(result.totalFiles == 10)
        #expect(result.groups.isEmpty)
        #expect(result.reclaimableBytes == 0)
    }

    @Test func keeperIsNewestByModificationDate() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "a/old.txt", modified: .test(secondsSince1970: 1_000_000))
        try temp.write("dup", to: "b/newest.txt", modified: .test(secondsSince1970: 3_000_000))
        try temp.write("dup", to: "c/middle.txt", modified: .test(secondsSince1970: 2_000_000))

        let result = try await engine.analyse(root: temp.url)
        let group = try #require(result.groups.first)

        #expect(group.keeper.path == temp.url(of: "b/newest.txt").path)
        #expect(group.redundant.count == 2)
    }

    @Test func keeperUsesNewestOfCreationOrModificationDate() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        // 修改日期更新的一份胜出（即便创建日期更早）
        try temp.write("dup", to: "a/older-modification.txt", modified: .test(secondsSince1970: 500), created: .test(secondsSince1970: 400))
        try temp.write("dup", to: "b/newer-modification.txt", modified: .test(secondsSince1970: 900), created: .test(secondsSince1970: 300))

        let result = try await engine.analyse(root: temp.url)
        let group = try #require(result.groups.first)

        #expect(group.keeper.path == temp.url(of: "b/newer-modification.txt").path)
    }

    @Test func keeperTieBreakIsPathOrder() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        let same = Date.test(secondsSince1970: 1_500_000)
        try temp.write("dup", to: "z.txt", modified: same)
        try temp.write("dup", to: "a.txt", modified: same)

        let result = try await engine.analyse(root: temp.url)
        let group = try #require(result.groups.first)

        #expect(group.keeper.path == temp.url(of: "a.txt").path)
    }

    @Test func statisticsBeforeAndAfterCleanup() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        // 3 份 4 字节重复 + 2 份 2 字节重复 + 1 个 4 字节唯一文件
        try temp.write("AAAA", to: "g1/a.txt")
        try temp.write("AAAA", to: "g1/b.txt")
        try temp.write("AAAA", to: "g1/c.txt")
        try temp.write("BB", to: "g2/a.txt")
        try temp.write("BB", to: "g2/b.txt")
        try temp.write("CCCC", to: "g3/uniq.txt")

        let result = try await engine.analyse(root: temp.url)

        #expect(result.totalFiles == 6)
        #expect(result.totalBytes == 20)
        #expect(result.duplicateGroupCount == 2)
        #expect(result.redundantFileCount == 3)
        #expect(result.reclaimableBytes == 10)
        #expect(result.filesAfterCleanup == 3)
        #expect(result.bytesAfterCleanup == 10)
    }

    @Test func largeFilesFallBackToFullHashing() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        var headA = Data(repeating: 0x41, count: 100_000)
        headA.append(Data(repeating: 0x11, count: 1_000))
        var headB = Data(repeating: 0x41, count: 100_000)
        headB.append(Data(repeating: 0x22, count: 1_000))

        try temp.write(headA, to: "a/one.bin")
        try temp.write(headA, to: "b/two.bin")
        try temp.write(headB, to: "c/three.bin")

        let result = try await engine.analyse(root: temp.url)

        #expect(result.duplicateGroupCount == 1)
        #expect(result.groups[0].files.count == 2)
        #expect(result.redundantFileCount == 1)
    }

    @Test func zeroByteFilesIgnoredByDefault() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write(Data(), to: "a/empty1.txt")
        try temp.write(Data(), to: "b/empty2.txt")

        #expect(try await engine.analyse(root: temp.url).groups.isEmpty)

        var options = ScanOptions()
        options.skipZeroLengthFiles = false
        let withZero = try await engine.analyse(root: temp.url, options: options)
        #expect(withZero.duplicateGroupCount == 1)
        #expect(withZero.redundantFileCount == 1)
    }

    @Test func hiddenFilesOptionTogglesDeduplication() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "a/visible.txt")
        try temp.write("dup", to: "b/.hidden.txt")

        #expect(try await engine.analyse(root: temp.url).groups.isEmpty)

        var options = ScanOptions()
        options.includeHiddenFiles = true
        #expect(try await engine.analyse(root: temp.url, options: options).duplicateGroupCount == 1)
    }

    @Test func minimumFileSizeOptionFiltersCandidates() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("AA", to: "a/small1.txt")
        try temp.write("AA", to: "b/small2.txt")

        var options = ScanOptions()
        options.minimumFileSize = 10
        #expect(try await engine.analyse(root: temp.url, options: options).groups.isEmpty)
    }

    @Test func zeroPartialHashBytesDoesNotCreateFalseDuplicates() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("content A", to: "a/one.txt")
        try temp.write("content B", to: "b/two.txt")
        try temp.write("content A", to: "c/three.txt")

        // 极端配置：partialHashBytes 被设为 0，内部必须做下限保护，
        // 否则所有文件都会哈希成「空内容」而被误判为重复。
        var options = ScanOptions()
        options.partialHashBytes = 0
        let result = try await engine.analyse(root: temp.url, options: options)

        #expect(result.totalFiles == 3)
        #expect(result.duplicateGroupCount == 1)
        #expect(result.redundantFileCount == 1)
    }

    @Test func emptyRootCompletesWithNoGroups() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        let result = try await engine.analyse(root: temp.url)

        #expect(result.totalFiles == 0)
        #expect(result.groups.isEmpty)
        #expect(result.filesAfterCleanup == 0)
    }

    @Test func missingRootThrowsNotADirectory() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        let missing = temp.url.appendingPathComponent("missing", isDirectory: true)
        do {
            _ = try await engine.analyse(root: missing)
            Issue.record("应当抛出 notADirectory")
        } catch let error as DedupError {
            #expect(error == .notADirectory(missing))
        } catch {
            Issue.record("错误类型不符合预期：\(error)")
        }
    }

    @Test func cancellingBeforeStartThrowsImmediately() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }
        try temp.write("dup", to: "a/1.txt")
        try temp.write("dup", to: "b/2.txt")

        let task = Task { try await engine.analyse(root: temp.url) }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test func cancellingDuringHashingStopsAnalysis() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        // 两个 512MB 的稀疏文件：内容相同，必须进入完整哈希阶段，保证取消点可被命中
        try temp.makeSparseFile("a/big.bin", size: 512 * 1_024 * 1_024)
        try temp.makeSparseFile("b/big.bin", size: 512 * 1_024 * 1_024)

        let task = Task { try await engine.analyse(root: temp.url) }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("任务应当被取消")
        } catch is CancellationError {
            #expect(Bool(true))
        }
    }

    @Test func progressPhasesAreReported() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "a/one.txt")
        try temp.write("dup", to: "b/two.txt")

        let collector = PhaseCollector()
        _ = try await engine.analyse(root: temp.url, progress: { collector.append($0) })

        let phases = collector.phases
        #expect(phases.contains(.scanning))
        #expect(phases.contains(.groupingBySize))
        #expect(phases.contains(.partialHashing))
        #expect(phases.last == .completed)
    }

    @Test func unreadableFileIsRecordedNotFatal() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "a/one.txt")
        try temp.write("dup", to: "b/two.txt")
        let locked = try temp.write("dup", to: "c/three.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let result = try await engine.analyse(root: temp.url)

        #expect(result.groups.isEmpty == false)
        #expect(result.unreadableFiles.isEmpty == false)
    }

    @Test func largeNumberOfFilesIsHandled() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        // 2,000 个文件中 1,000 份重复（500 组）
        for index in 0..<500 {
            try temp.write("dup-\(index)", to: "a/f-\(index).txt")
            try temp.write("dup-\(index)", to: "b/f-\(index).txt")
        }
        for index in 0..<1_000 {
            try temp.write("unique-\(index)", to: "c/u-\(index).txt")
        }

        let result = try await engine.analyse(root: temp.url)

        #expect(result.totalFiles == 2_000)
        #expect(result.duplicateGroupCount == 500)
        #expect(result.redundantFileCount == 500)
        #expect(result.filesAfterCleanup == 1_500)
    }
}
