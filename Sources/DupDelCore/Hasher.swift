import CryptoKit
import Darwin
import Foundation

/// SHA-256 增量哈希：
/// - 复用同一块缓冲区做 POSIX read，避免海量文件场景下反复分配 Data；
/// - 直接把裸指针交给 CryptoKit，省去一次内存拷贝；
/// - 打开 F_NOCACHE，扫描大文件时不会把系统页缓存冲掉（整机卡顿的主因之一）。
public enum FileHasher {
    /// 超过该体积的读取才关闭页缓存（8 MB）。
    private static let noCacheThreshold: Int64 = 8 * 1_024 * 1_024

    private static let hexTable: [String] = {
        var table = [String]()
        table.reserveCapacity(256)
        for value in 0..<256 {
            table.append(String(format: "%02x", value))
        }
        return table
    }()

    /// - Parameters:
    ///   - maxBytes: 只哈希前 N 个字节（快速校验）；nil 表示整文件。
    ///   - bufferSize: 每次读取的块大小。
    public static func hash(url: URL, maxBytes: Int? = nil, bufferSize: Int = 1 << 20) throws -> String {
        let descriptor = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let path = pointer else { return -1 }
            return open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw DedupError.readFailed(url, "无法打开（errno \(errno)）")
        }
        defer { close(descriptor) }
        // 只对「确实很大」的读取关闭页缓存：
        // 大文件顺序扫描不必污染系统缓存；小文件走缓存更快（实测小文件关缓存会慢数倍）。
        var fileSize: Int64 = Int64.max
        var info = stat()
        if fstat(descriptor, &info) == 0 { fileSize = Int64(info.st_size) }
        let plannedBytes = Swift.min(Int64(maxBytes ?? Int.max), fileSize)
        if plannedBytes > Self.noCacheThreshold {
            fcntl(descriptor, F_NOCACHE, 1)
        }

        // 缓冲区按「本次实际要读的字节数」分配：
        // 小文件用 4KB，避免海量小文件时反复分配并清零 1MB 缓冲区。
        let planned = Swift.min(Int64(maxBytes ?? Int.max), fileSize)
        let chunk = Swift.max(4_096, Swift.min(bufferSize, Int(Swift.max(1, planned))))

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 1)
        defer { buffer.deallocate() }

        var hasher = SHA256()
        var remaining = Int(Swift.min(planned, Int64(Int.max)))

        while remaining > 0 {
            let want = Swift.min(chunk, remaining)
            let bytesRead = read(descriptor, buffer.baseAddress, want)
            let errorCode = errno

            if bytesRead < 0 {
                if errorCode == EINTR { continue }
                throw DedupError.readFailed(url, "读取失败（errno \(errorCode)）")
            }
            if bytesRead == 0 { break }

            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer.baseAddress, count: bytesRead))
            remaining -= bytesRead
            if bytesRead < want { break }
        }

        return hexString(hasher.finalize())
    }

    public static func hash(data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        return hexString(hasher.finalize())
    }

    private static func hexString(_ digest: SHA256Digest) -> String {
        var output = ""
        output.reserveCapacity(64)
        for byte in digest {
            output += hexTable[Int(byte)]
        }
        return output
    }
}
