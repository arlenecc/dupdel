import Foundation
import Testing
@testable import DupDelCore

@Suite struct CleanerTests {
    private let engine = DedupEngine()
    private let cleaner = Cleaner()

    @Test func cleanDeletesRedundantCopiesAndKeepsNewest() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "a/old.txt", modified: .test(secondsSince1970: 1_000))
        try temp.write("dup", to: "b/newest.txt", modified: .test(secondsSince1970: 3_000))
        try temp.write("dup", to: "c/middle.txt", modified: .test(secondsSince1970: 2_000))
        try temp.write("unique", to: "d/keep.txt")

        let analysis = try await engine.analyse(root: temp.url)
        let result = cleaner.clean(groups: analysis.groups, root: temp.url)

        #expect(result.deletedFiles == 2)
        #expect(result.reclaimedBytes == 6)
        #expect(temp.exists("b/newest.txt"))
        #expect(temp.exists("a/old.txt") == false)
        #expect(temp.exists("c/middle.txt") == false)
        #expect(temp.exists("d/keep.txt"))
    }

    @Test func cleanPrunesEmptyDirectoriesRecursively() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "level1/level2/old.txt", modified: .test(secondsSince1970: 1_000))
        try temp.write("dup", to: "keep/newest.txt", modified: .test(secondsSince1970: 2_000))

        let analysis = try await engine.analyse(root: temp.url)
        let result = cleaner.clean(groups: analysis.groups, root: temp.url)

        #expect(result.deletedFiles == 1)
        #expect(result.prunedDirectories == 2)
        #expect(temp.exists("level1") == false)
        #expect(temp.exists("keep/newest.txt"))
        #expect(FileManager.default.fileExists(atPath: temp.url.path))
    }

    @Test func cleanKeepsNonEmptyDirectories() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "mixed/old.txt", modified: .test(secondsSince1970: 1_000))
        try temp.write("dup", to: "other/newest.txt", modified: .test(secondsSince1970: 2_000))
        try temp.write("sibling", to: "mixed/sibling.txt")

        let analysis = try await engine.analyse(root: temp.url)
        let result = cleaner.clean(groups: analysis.groups, root: temp.url)

        #expect(temp.exists("mixed"))
        #expect(temp.exists("mixed/sibling.txt"))
        #expect(result.prunedDirectories == 0)
    }

    @Test func pruneCanBeDisabled() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "empty-me/old.txt", modified: .test(secondsSince1970: 1_000))
        try temp.write("dup", to: "keeper/newest.txt", modified: .test(secondsSince1970: 2_000))

        let analysis = try await engine.analyse(root: temp.url)
        var options = CleanOptions()
        options.pruneEmptyDirectories = false
        let result = cleaner.clean(groups: analysis.groups, root: temp.url, options: options)

        #expect(result.deletedFiles == 1)
        #expect(result.prunedDirectories == 0)
        #expect(temp.exists("empty-me"))
    }

    @Test func cleanNeverDeletesRootEvenWhenItBecomesEmpty() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "old.txt", modified: .test(secondsSince1970: 1_000))
        try temp.write("dup", to: "newest.txt", modified: .test(secondsSince1970: 2_000))

        let analysis = try await engine.analyse(root: temp.url)
        let result = cleaner.clean(groups: analysis.groups, root: temp.url)

        #expect(result.deletedFiles == 1)
        #expect(FileManager.default.fileExists(atPath: temp.url.path))
        // 保留的一份仍在根目录，根目录本身不应被删除
        #expect(try temp.contentsOfRoot().count == 1)
    }

    @Test func dryRunDeletesNothingButReportsNumbers() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "a/old.txt", modified: .test(secondsSince1970: 1_000))
        try temp.write("dup", to: "b/newest.txt", modified: .test(secondsSince1970: 2_000))

        let analysis = try await engine.analyse(root: temp.url)
        var options = CleanOptions()
        options.dryRun = true
        let result = cleaner.clean(groups: analysis.groups, root: temp.url, options: options)

        #expect(result.deletedFiles == 1)
        #expect(result.reclaimedBytes == 3)
        #expect(result.prunedDirectories == 0)
        #expect(temp.exists("a/old.txt"))
        #expect(temp.exists("b/newest.txt"))
    }

    @Test func filesOutsideRootAreNeverDeleted() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }
        let other = try TempDirectory()
        defer { other.cleanup() }

        let outside = try other.write("dup", to: "outside.txt", modified: .test(secondsSince1970: 1_000))
        let inside = try temp.write("dup", to: "inside.txt", modified: .test(secondsSince1970: 2_000))

        let group = DuplicateGroup(
            hash: "manual",
            files: [
                FileEntry(url: outside, size: 3, modified: .test(secondsSince1970: 1_000), created: .test(secondsSince1970: 1_000)),
                FileEntry(url: inside, size: 3, modified: .test(secondsSince1970: 2_000), created: .test(secondsSince1970: 2_000)),
            ]
        )

        let result = cleaner.clean(groups: [group], root: temp.url)

        #expect(result.deletedFiles == 0)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: inside.path))
    }

    @Test func cancellationStopsDeletion() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "a/old.txt", modified: .test(secondsSince1970: 1_000))
        try temp.write("dup", to: "b/newest.txt", modified: .test(secondsSince1970: 2_000))

        let analysis = try await engine.analyse(root: temp.url)
        let result = cleaner.clean(groups: analysis.groups, root: temp.url, isCancelled: { true })

        #expect(result.deletedFiles == 0)
        #expect(temp.exists("a/old.txt"))
    }

    @Test func deleteFailureIsRecorded() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        let lockedDirectory = try temp.makeDirectory("locked")
        let lockedFile = try temp.write("dup", to: "locked/old.txt", modified: .test(secondsSince1970: 1_000))
        try temp.write("dup", to: "free/newest.txt", modified: .test(secondsSince1970: 2_000))

        let analysis = try await engine.analyse(root: temp.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDirectory.path) }

        let result = cleaner.clean(groups: analysis.groups, root: temp.url)

        #expect(result.failures.count == 1)
        #expect(result.failures.first?.url.path == lockedFile.path)
        #expect(FileManager.default.fileExists(atPath: lockedFile.path))
    }

    @Test func filesRemovedAfterAnalysisAreSkippedNotFailed() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "a/old.txt", modified: .test(secondsSince1970: 1_000))
        try temp.write("dup", to: "b/newest.txt", modified: .test(secondsSince1970: 2_000))

        let analysis = try await engine.analyse(root: temp.url)
        // 模拟分析之后、清理之前文件被外部删除
        try FileManager.default.removeItem(at: temp.url(of: "a/old.txt"))

        let result = cleaner.clean(groups: analysis.groups, root: temp.url)

        #expect(result.deletedFiles == 0)
        #expect(result.missingFiles == 1)
        #expect(result.failures.isEmpty)
    }

    @Test func trashModeRemovesFiles() async throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("dup", to: "a/old.txt", modified: .test(secondsSince1970: 1_000))
        try temp.write("dup", to: "b/newest.txt", modified: .test(secondsSince1970: 2_000))

        let analysis = try await engine.analyse(root: temp.url)
        var options = CleanOptions()
        options.useTrash = true
        let result = cleaner.clean(groups: analysis.groups, root: temp.url, options: options)

        if result.failures.isEmpty {
            #expect(result.deletedFiles == 1)
            #expect(temp.exists("a/old.txt") == false)
        } else {
            withKnownIssue("当前环境不支持移到废纸篓：\(result.failures.first?.reason ?? "")") {
                #expect(result.failures.isEmpty)
            }
        }
    }
}
