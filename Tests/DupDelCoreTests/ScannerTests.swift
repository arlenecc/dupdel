import Foundation
import Testing
@testable import DupDelCore

@Suite struct ScannerTests {
    private let scanner = FileScanner()

    @Test func scanCountsAllFilesAndBytes() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("hello", to: "a/1.txt")
        try temp.write("world", to: "a/2.txt")
        try temp.write("abcde", to: "b/c/3.txt")

        let outcome = try scanner.scan(root: temp.url)

        #expect(outcome.totalFiles == 3)
        #expect(outcome.totalBytes == 15)
        #expect(outcome.skippedFiles == 0)
    }

    @Test func scanEmptyRoot() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        let outcome = try scanner.scan(root: temp.url)

        #expect(outcome.totalFiles == 0)
        #expect(outcome.totalBytes == 0)
        #expect(outcome.buckets.isEmpty)
    }

    @Test func scanMissingRootThrowsNotADirectory() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        let missing = temp.url.appendingPathComponent("nope", isDirectory: true)
        #expect { try scanner.scan(root: missing) } throws: { error in
            error as? DedupError == .notADirectory(missing)
        }
    }

    @Test func scanFileAsRootThrowsNotADirectory() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        let file = try temp.write("x", to: "file.txt")
        #expect { try scanner.scan(root: file) } throws: { error in
            error as? DedupError == .notADirectory(file)
        }
    }

    @Test func scanSkipsHiddenByDefaultAndIncludesWhenEnabled() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("visible", to: "visible.txt")
        try temp.write("hidden", to: ".hidden.txt")

        #expect(try scanner.scan(root: temp.url).totalFiles == 1)

        var options = ScanOptions()
        options.includeHiddenFiles = true
        #expect(try scanner.scan(root: temp.url, options: options).totalFiles == 2)
    }

    @Test func scanSkipsZeroLengthByDefaultAndIncludesWhenEnabled() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write(Data(), to: "empty.txt")
        try temp.write("data", to: "data.txt")

        #expect(try scanner.scan(root: temp.url).totalFiles == 1)

        var options = ScanOptions()
        options.skipZeroLengthFiles = false
        #expect(try scanner.scan(root: temp.url, options: options).totalFiles == 2)
    }

    @Test func scanIgnoresSymlinks() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        let target = try temp.write("payload", to: "real/target.txt")
        try FileManager.default.createSymbolicLink(at: temp.url(of: "link.txt"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: temp.url(of: "broken.txt"), withDestinationURL: temp.url(of: "missing.txt"))

        let outcome = try scanner.scan(root: temp.url)

        #expect(outcome.totalFiles == 1)
        #expect(outcome.skippedFiles == 2)
    }

    @Test func scanAppliesMinimumSizeFilter() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("small", to: "small.txt")
        try temp.write("large-content", to: "large.txt")

        var options = ScanOptions()
        options.minimumFileSize = 10
        let outcome = try scanner.scan(root: temp.url, options: options)

        #expect(outcome.totalFiles == 1)
        #expect(outcome.skippedFiles == 1)
    }

    @Test func scanHandlesDeepNesting() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        var path = "d0"
        for depth in 1..<40 { path += "/d\(depth)" }
        try temp.write("deep", to: "\(path)/file.txt")

        #expect(try scanner.scan(root: temp.url).totalFiles == 1)
    }

    @Test func scanOnlyKeepsDuplicatedSizeBuckets() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        try temp.write("unique", to: "uniq.txt")   // 6 字节，唯一体积
        try temp.write("dup1", to: "dup1.txt")     // 4 字节
        try temp.write("dup2", to: "dup2.txt")     // 4 字节

        let outcome = try scanner.scan(root: temp.url)

        #expect(outcome.totalFiles == 3)
        #expect(outcome.buckets.count == 1)
        #expect(outcome.buckets[4]?.count == 2)
    }

    @Test func scanCancellationThrows() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        for index in 0..<200 {
            try temp.write("file-\(index)", to: "dir/file-\(index).txt")
        }

        #expect(throws: CancellationError.self) {
            try scanner.scan(root: temp.url, isCancelled: { true })
        }
    }

    @Test func scanReportsProgressPeriodically() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        for index in 0..<1_200 {
            try temp.write("file-\(index)", to: "dir/file-\(index).txt")
        }

        let counter = Counter()
        _ = try scanner.scan(root: temp.url, onProgress: { _, _ in counter.increment() })

        #expect(counter.value > 1)
    }
}
