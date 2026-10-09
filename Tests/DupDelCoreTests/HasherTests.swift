import Foundation
import Testing
@testable import DupDelCore

@Suite struct HasherTests {
    @Test func sameContentProducesSameHash() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        let first = try temp.write("same content", to: "a.txt")
        let second = try temp.write("same content", to: "b.txt")

        #expect(try FileHasher.hash(url: first) == FileHasher.hash(url: second))
    }

    @Test func differentContentProducesDifferentHash() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        let first = try temp.write("content A", to: "a.txt")
        let second = try temp.write("content B", to: "b.txt")

        #expect(try FileHasher.hash(url: first) != FileHasher.hash(url: second))
    }

    @Test func partialHashCanCollideWhileFullHashDiffers() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        var head = Data(repeating: 0x41, count: 100)
        head.append(Data(repeating: 0x42, count: 100))
        let first = try temp.write(head, to: "first.bin")
        var secondData = Data(repeating: 0x41, count: 100)
        secondData.append(Data(repeating: 0x43, count: 100))
        let second = try temp.write(secondData, to: "second.bin")

        #expect(try FileHasher.hash(url: first, maxBytes: 64) == FileHasher.hash(url: second, maxBytes: 64))
        #expect(try FileHasher.hash(url: first) != FileHasher.hash(url: second))
    }

    @Test func nilMaxBytesHashesWholeFile() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        let file = try temp.write(String(repeating: "x", count: 5_000), to: "big.txt")
        #expect(try FileHasher.hash(url: file) == FileHasher.hash(url: file, maxBytes: nil))
    }

    @Test func chunkedHashMatchesWholeDataHash() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        var data = Data()
        for index in 0..<300_000 { data.append(UInt8(truncatingIfNeeded: index)) }
        let file = try temp.write(data, to: "large.bin")

        #expect(try FileHasher.hash(url: file, bufferSize: 4_096) == FileHasher.hash(data: data))
    }

    @Test func smallFileWithMaxBytesProducesFullHash() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        let file = try temp.write("tiny", to: "tiny.txt")
        #expect(try FileHasher.hash(url: file, maxBytes: 1_024) == FileHasher.hash(data: Data("tiny".utf8)))
    }

    @Test func missingFileThrowsReadFailed() throws {
        let temp = try TempDirectory()
        defer { temp.cleanup() }

        let missing = temp.url(of: "missing.bin")
        #expect { try FileHasher.hash(url: missing) } throws: { error in
            guard case .readFailed(let url, _) = error as? DedupError else { return false }
            return url == missing
        }
    }
}
