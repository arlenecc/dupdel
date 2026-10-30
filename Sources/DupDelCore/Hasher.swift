import CryptoKit
import Darwin
import Foundation

/// 同一份物理数据的身份标识（设备 + inode）。
/// 硬链接（同一 inode 的多个目录项）共享该身份：删除其中任一份都不会释放空间。
public struct FileIdentity: Sendable, Hashable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// 文件的即时属性快照。
public struct FileStat: Sendable, Hashable {
    public let size: UInt64
    public let device: UInt64
    public let inode: UInt64

    public init(size: UInt64, device: UInt64, inode: UInt64) {
        self.size = size
        self.device = device
        self.inode = inode
    }

    public var identity: FileIdentity { FileIdentity(device: device, inode: inode) }
}

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
    ///
    /// 重要：本函数保证「哈希的字节数 == 预期字节数」，不足则抛错。
    /// 若读取被截断却静默返回，得到的是某个前缀的哈希——内容不同的文件可能因此
    /// 得到相同哈希而被误判为重复（并被删除）。
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
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw DedupError.readFailed(url, "无法读取文件属性（errno \(errno)）")
        }
        let fileSize = Int64(info.st_size)
        let planned = Swift.min(Int64(maxBytes ?? Int.max), fileSize)
        if planned > Self.noCacheThreshold {
            fcntl(descriptor, F_NOCACHE, 1)
        }

        // 缓冲区按「本次实际要读的字节数」分配：
        // 小文件用 4KB，避免海量小文件时反复分配并清零 1MB 缓冲区。
        let chunk = Swift.max(4_096, Swift.min(bufferSize, Int(Swift.max(1, planned))))

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 1)
        defer { buffer.deallocate() }

        var hasher = SHA256()
        var remaining = planned

        while remaining > 0 {
            let want = Int(Swift.min(Int64(chunk), remaining))
            let bytesRead = read(descriptor, buffer.baseAddress, want)
            let errorCode = errno

            if bytesRead < 0 {
                if errorCode == EINTR { continue }
                throw DedupError.readFailed(url, "读取失败（errno \(errorCode)）")
            }
            // 只有「读到 0 字节」才是真正的 EOF。
            // 读到的比请求的少（短读）并不代表文件结束：网络卷 / 云盘未落地的文件 /
            // 被并发改写的文件都可能出现，必须继续读，否则会算出某个前缀的哈希。
            if bytesRead == 0 { break }

            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer.baseAddress, count: bytesRead))
            remaining -= Int64(bytesRead)
        }

        // 没读满预期字节数：结果不可信，必须报错让调用方跳过该文件，
        // 而不是拿「前缀哈希」参与比较。
        guard remaining == 0 else {
            throw DedupError.readFailed(
                url,
                "读取不完整（预期 \(planned) 字节，实际 \(planned - remaining) 字节）"
            )
        }

        return hexString(hasher.finalize())
    }

    /// 读取文件当前属性（体积 / 设备 / inode）；读取失败返回 nil。
    ///
    /// 用途：①校验「扫描时记录的体积」与「哈希时的体积」是否一致，
    /// 避免使用过期体积分组；②识别硬链接（同一 inode 的多个目录项）。
    public static func fileStat(url: URL) -> FileStat? {
        url.withUnsafeFileSystemRepresentation { pointer -> FileStat? in
            guard let path = pointer else { return nil }
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return FileStat(size: UInt64(info.st_size), device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        }
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
