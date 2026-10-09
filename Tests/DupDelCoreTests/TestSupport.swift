import Darwin
import DupDelCore
import Foundation

/// 测试用的临时目录沙箱。
struct TempDirectory {
    let url: URL

    init(name: String = UUID().uuidString) throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DupDelTests-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // 规范化真实路径后再使用：/var 在 macOS 上是 firmlink（指向 /private/var），
        // FileManager 枚举返回的是真实路径，这里保持一致便于路径断言。
        url = URL(fileURLWithPath: Self.realPath(base.path), isDirectory: true)
    }

    private static func realPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let target = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func write(
        _ content: String,
        to relativePath: String,
        modified: Date? = nil,
        created: Date? = nil
    ) throws -> URL {
        try write(Data(content.utf8), to: relativePath, modified: modified, created: created)
    }

    @discardableResult
    func write(
        _ data: Data,
        to relativePath: String,
        modified: Date? = nil,
        created: Date? = nil
    ) throws -> URL {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        var attributes: [FileAttributeKey: Any] = [:]
        if let modified { attributes[.modificationDate] = modified }
        if let created { attributes[.creationDate] = created }
        if !attributes.isEmpty {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: target.path)
        }
        return target
    }

    /// 创建稀疏大文件：瞬间完成、不占磁盘，用于测试大文件哈希与取消逻辑。
    @discardableResult
    func makeSparseFile(_ relativePath: String, size: UInt64) throws -> URL {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw MakeFileError.createFailed(target)
        }
        let descriptor = open(target.path, O_WRONLY)
        guard descriptor >= 0 else { throw MakeFileError.openFailed(target) }
        defer { close(descriptor) }
        guard ftruncate(descriptor, Int64(size)) == 0 else { throw MakeFileError.truncateFailed(target) }
        return target
    }

    func url(of relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(of: relativePath).path)
    }

    func contents(ofDirectory relativePath: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url(of: relativePath).path)
    }

    func contentsOfRoot() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
    }
}

enum MakeFileError: Error {
    case createFailed(URL)
    case openFailed(URL)
    case truncateFailed(URL)
}

extension Date {
    static func test(secondsSince1970: TimeInterval) -> Date {
        Date(timeIntervalSince1970: secondsSince1970)
    }
}

/// 后台线程安全计数器。
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// 收集分析过程上报的阶段。
final class PhaseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Phase] = []

    func append(_ update: ProgressUpdate) {
        lock.lock()
        values.append(update.phase)
        lock.unlock()
    }

    var phases: [Phase] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
