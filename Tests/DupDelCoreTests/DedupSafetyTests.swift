import Foundation
import Testing
@testable import DupDelCore

/// 重复判定的安全性回归：宁可漏判，也不能把内容不同的文件判成重复并删除。
@Suite struct DedupSafetyTests {
    private let engine = DedupEngine()
    private let cleaner = Cleaner()

    private func pseudoRandom(_ count: Int, seed: UInt64) -> Data {
        var generator = seed
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0..<count {
                generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                base[index] = UInt8(truncatingIfNeeded: generator >> 33)
            }
        }
        return data
    }

    @Test func sameSizedDifferentLargeFilesAreNotGrouped() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        // 12MB > 8MB 的 F_NOCACHE 阈值，同时覆盖多块读取路径
        for index in 0..<6 {
            try temp.write(pseudoRandom(12 * 1_024 * 1_024, seed: UInt64(index) + 1), to: "big/f-\(index).bin")
        }

        let result = try await engine.analyse(root: temp.url)
        #expect(result.totalFiles == 6)
        #expect(result.duplicateGroupCount == 0)
    }

    @Test func sharedHeadDifferentTailIsNeverGrouped() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        var head = Data()
        for index in 0..<70_000 { head.append(UInt8(truncatingIfNeeded: index)) }
        for index in 0..<4 {
            var payload = head
            payload.append(pseudoRandom(30_000, seed: UInt64(index) + 77))
            try temp.write(payload, to: "shared/f-\(index).bin")
        }

        #expect(try await engine.analyse(root: temp.url).duplicateGroupCount == 0)
    }

    @Test func hardLinksAreNotReportedAsDuplicates() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        let original = try temp.write("dup", to: "a/one.txt")
        try temp.makeDirectory("b")
        try FileManager.default.linkItem(at: original, to: temp.url(of: "b/two.txt"))
        // 真副本（内容相同但数据各存一份）仍然必须成组
        try temp.write("dup", to: "c/three.txt")

        let result = try await engine.analyse(root: temp.url)

        #expect(result.totalFiles == 3)
        #expect(result.duplicateGroupCount == 1)
        let group = try #require(result.groups.first)
        // 同一 inode 的两个目录项只占一份，真正可回收的只有第三个副本
        #expect(group.files.count == 2)
        #expect(result.redundantFileCount == 1)
        #expect(result.reclaimableBytes == 3)
    }

    @Test func redundantCopyChangedAfterAnalysisIsNotDeleted() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "a/old.txt", modified: .test(secondsSince1970: 1_000))
        try temp.write("dup", to: "b/newest.txt", modified: .test(secondsSince1970: 3_000))
        try temp.write("dup", to: "c/middle.txt", modified: .test(secondsSince1970: 2_000))

        let analysis = try await engine.analyse(root: temp.url)
        // 分析之后、清理之前，其中一份副本被改动
        try temp.write("dup-changed", to: "a/old.txt", modified: .test(secondsSince1970: 1_000))

        let result = cleaner.clean(groups: analysis.groups, root: temp.url)

        #expect(result.deletedFiles == 1)
        #expect(result.unverifiedFiles == 1)
        #expect(result.failedFiles == 0)
        #expect(temp.exists("a/old.txt"))
        #expect(temp.exists("b/newest.txt"))
        #expect(temp.exists("c/middle.txt") == false)
    }

    @Test func verificationCanBeDisabled() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "a/old.txt", modified: .test(secondsSince1970: 1_000))
        try temp.write("dup", to: "b/newest.txt", modified: .test(secondsSince1970: 2_000))

        let analysis = try await engine.analyse(root: temp.url)
        try temp.write("dup-changed", to: "a/old.txt", modified: .test(secondsSince1970: 1_000))

        var options = CleanOptions()
        options.verifyBeforeDeleting = false
        let result = cleaner.clean(groups: analysis.groups, root: temp.url, options: options)

        #expect(result.deletedFiles == 1)
        #expect(result.unverifiedFiles == 0)
        #expect(temp.exists("a/old.txt") == false)
    }
}
