import AppKit
import DupDelCore
import Foundation
import SwiftUI

/// 后台线程产生的事件，安全地转投到主线程。
final class EventRelay: @unchecked Sendable {
    private let handler: @MainActor (WorkerEvent) -> Void

    init(handler: @escaping @MainActor (WorkerEvent) -> Void) {
        self.handler = handler
    }

    func send(_ event: WorkerEvent) {
        let handler = handler
        Task { @MainActor in handler(event) }
    }
}

enum WorkerEvent: Sendable {
    case progress(ProgressUpdate)
    case cleaning(processed: Int, total: Int, path: String)
}

/// 后台线程侧的节流器：在投递到主线程之前就丢弃高频事件，
/// 避免海量文件删除时每秒创建上万个 MainActor 任务。
final class Throttler: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var lastDate: Date = .distantPast

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func pass() -> Bool {
        let now = Date()
        lock.lock()
        let shouldPass = now.timeIntervalSince(lastDate) >= interval
        if shouldPass { lastDate = now }
        lock.unlock()
        return shouldPass
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    struct LogEntry: Identifiable, Equatable {
        enum Level: String {
            case info
            case success
            case warning
            case error
        }

        let id: Int
        let time: Date
        let level: Level
        let text: String
    }

    // MARK: - 配置区

    @Published var rootPath: String = ""
    @Published var includeHiddenFiles = false
    @Published var skipZeroLengthFiles = true
    @Published var pruneEmptyDirectories = true
    @Published var useTrash = false
    @Published var minimumSizeKB = 0
    @Published var concurrencyChoice = 0

    // MARK: - 运行状态

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = ProgressUpdate(phase: .idle)
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var analysis: AnalysisResult?
    @Published private(set) var cleanSummary: CleanResult?
    @Published private(set) var isWorking = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var showCleanConfirmation = false

    /// 列表只渲染前 N 组，避免海量重复组拖垮 UI。
    static let maxRenderedGroups = 2_000
    private static let maxLogEntries = 3_000

    private let engine = DedupEngine()
    private let cleaner = Cleaner()

    private var task: Task<Void, Never>?
    /// 操作代号：用于丢弃旧任务的收尾回调，避免覆盖新任务的状态。
    private var operationGeneration = 0
    private var startedAt: Date?
    private var timer: Timer?
    private var logCounter = 0
    private var lastLoggedPhase: Phase = .idle
    private var lastLogDate: Date = .distantPast
    private var lastProgressDate: Date = .distantPast
    private var displayedGroupsCache: [DuplicateGroup] = []

    // MARK: - 派生状态

    var canAnalyse: Bool {
        !trimmedPath.isEmpty && !isWorking
    }

    private var trimmedPath: String {
        rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canClean: Bool {
        !isWorking && (analysis?.duplicateGroupCount ?? 0) > 0
    }

    /// 列表只渲染前 maxRenderedGroups 组，缓存结果避免每次刷新都拷贝数组。
    var displayedGroups: [DuplicateGroup] { displayedGroupsCache }

    var hiddenGroupCount: Int {
        max(0, (analysis?.duplicateGroupCount ?? 0) - displayedGroupsCache.count)
    }

    private func updateAnalysis(_ result: AnalysisResult?) {
        analysis = result
        displayedGroupsCache = result.map { Array($0.groups.prefix(Self.maxRenderedGroups)) } ?? []
    }

    var progressValue: Double? {
        switch phase {
        case .idle:
            return 0
        case .completed:
            return 1
        case .cancelled, .failed:
            return nil
        case .scanning:
            // 扫描阶段文件总数未知，使用不确定进度
            return nil
        case .cleaning:
            return progress.total > 0 ? progress.fraction : nil
        default:
            return progress.total > 0 ? progress.overall : nil
        }
    }

    var statusText: String {
        if isWorking {
            return "\(phase.displayName)：\(progress.detail)"
        }
        switch phase {
        case .idle:
            return "请选择目录并开始分析"
        case .completed:
            return "分析完成，共 \(ByteFormatter.count(analysis?.duplicateGroupCount ?? 0)) 组重复文件"
        case .cancelled:
            return "已取消"
        case .failed:
            return "处理失败"
        case .cleaning:
            return "清理中"
        default:
            return phase.displayName
        }
    }

    // MARK: - 目录选择

    /// 目录变化后丢弃上一次的结果，避免展示与当前目录不符的统计。
    func rootPathDidChange(_ path: String) {
        guard analysis != nil || cleanSummary != nil else { return }
        guard let root = analysis?.root, root.path != path.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        updateAnalysis(nil)
        cleanSummary = nil
        phase = .idle
        progress = ProgressUpdate(phase: .idle)
        appendLog("目录已变更，已清空上一次的分析结果", level: .info)
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择需要排重的目录"
        if !rootPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootPath = url.path
        appendLog("已选择目录：\(url.path)")
    }

    func revealInFinder() {
        guard !rootPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: rootPath, isDirectory: true))
    }

    // MARK: - 分析

    func startAnalysis() {
        guard canAnalyse else { return }
        cancel()

        let root = URL(fileURLWithPath: trimmedPath, isDirectory: true)
        var options = ScanOptions()
        options.includeHiddenFiles = includeHiddenFiles
        options.skipZeroLengthFiles = skipZeroLengthFiles
        options.minimumFileSize = UInt64(max(0, minimumSizeKB)) * 1_024
        options.partialHashBytes = 64 * 1_024
        options.maxHashingConcurrency = concurrencyChoice

        operationGeneration += 1
        let generation = operationGeneration
        updateAnalysis(nil)
        cleanSummary = nil
        phase = .scanning
        progress = ProgressUpdate(phase: .scanning)
        isWorking = true
        startedAt = Date()
        elapsed = 0
        resetLogThrottling()
        startTimer()

        appendLog("开始分析：\(root.path)")
        appendLog("配置：隐藏文件 \(includeHiddenFiles ? "包含" : "忽略")，0 字节文件 \(skipZeroLengthFiles ? "忽略" : "包含")，最小体积 \(minimumSizeKB) KB，并发 \(concurrencyChoice == 0 ? "自动" : "\(concurrencyChoice)")")

        let relay = EventRelay { [weak self] event in
            self?.handle(event)
        }

        task = Task {
            do {
                let result = try await engine.analyse(root: root, options: options) { update in
                    relay.send(.progress(update))
                }
                guard !Task.isCancelled else { throw CancellationError() }
                updateAnalysis(result)
                phase = .completed
                progress = ProgressUpdate(phase: .completed, processed: 1, total: 1, detail: "分析完成")
                summarize(result)
            } catch is CancellationError {
                phase = .cancelled
                progress = ProgressUpdate(phase: .cancelled)
                appendLog("已取消当前操作", level: .warning)
            } catch {
                phase = .failed
                progress = ProgressUpdate(phase: .failed)
                errorMessage = error.localizedDescription
                appendLog("分析失败：\(error.localizedDescription)", level: .error)
            }
            finishOperation(generation: generation)
        }
    }

    /// 只有最新一次操作才允许收尾，避免被取消的旧任务清掉新任务的状态。
    private func finishOperation(generation: Int) {
        guard generation == operationGeneration else { return }
        isWorking = false
        stopTimer()
        task = nil
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - 清理

    func clean() {
        guard let analysis, canClean else { return }
        let groups = analysis.groups
        let root = analysis.root
        var options = CleanOptions()
        options.useTrash = useTrash
        options.pruneEmptyDirectories = pruneEmptyDirectories

        let cleaner = self.cleaner
        let cleanOptions = options
        operationGeneration += 1
        let generation = operationGeneration
        isWorking = true
        phase = .cleaning
        startedAt = Date()
        elapsed = 0
        resetLogThrottling()
        startTimer()
        appendLog("开始清理：共 \(ByteFormatter.count(groups.count)) 组，预计删除 \(ByteFormatter.count(analysis.redundantFileCount)) 个文件")

        let relay = EventRelay { [weak self] event in
            self?.handle(event)
        }
        let throttler = Throttler(interval: 0.1)

        task = Task {
            let flag = CancelFlag()
            do {
                let result = try await withTaskCancellationHandler {
                    try await Background.run {
                        cleaner.clean(
                            groups: groups,
                            root: root,
                            options: cleanOptions,
                            isCancelled: { flag.isCancelled }
                        ) { processed, total, path in
                            guard processed == total || throttler.pass() else { return }
                            relay.send(.cleaning(processed: processed, total: total, path: path))
                        }
                    }
                } onCancel: {
                    flag.cancel()
                }
                cleanSummary = result
                phase = .completed
                progress = ProgressUpdate(phase: .completed, processed: 1, total: 1, detail: "清理完成")
                appendLog(
                    "清理完成：删除 \(ByteFormatter.count(result.deletedFiles)) 个文件，回收 \(ByteFormatter.string(result.reclaimedBytes))，删除空目录 \(ByteFormatter.count(result.prunedDirectories)) 个",
                    level: .success
                )
                if result.missingFiles > 0 {
                    appendLog("其中 \(ByteFormatter.count(result.missingFiles)) 个文件在分析后已被移除，自动跳过", level: .warning)
                }
                if result.unverifiedFiles > 0 {
                    appendLog("其中 \(ByteFormatter.count(result.unverifiedFiles)) 个文件在分析后内容发生变化，复核未通过，已安全保留", level: .warning)
                }
                for failure in result.failures.prefix(5) {
                    appendLog("删除失败: \(failure.url.path) (\(failure.reason))", level: .error)
                }
                // 全部成功时用实际结果刷新统计（避免数字失真）；
                // 有失败项时保留原结果，方便修复权限后重试。
                if result.failedFiles == 0 {
                    updateAnalysis(
                        AnalysisResult(
                            root: root,
                            totalFiles: max(0, analysis.totalFiles - result.deletedFiles),
                            totalBytes: analysis.totalBytes > result.reclaimedBytes ? analysis.totalBytes - result.reclaimedBytes : 0,
                            groups: [],
                            skippedFiles: analysis.skippedFiles,
                            inaccessibleDirectories: analysis.inaccessibleDirectories,
                            unreadableFiles: analysis.unreadableFiles,
                            duration: analysis.duration
                        )
                    )
                } else {
                    appendLog("存在 \(ByteFormatter.count(result.failedFiles)) 个删除失败的文件，已保留列表，可修复权限后再次清理", level: .warning)
                }
            } catch is CancellationError {
                phase = .cancelled
                appendLog("已取消清理", level: .warning)
            } catch {
                phase = .failed
                errorMessage = error.localizedDescription
                appendLog("清理失败：\(error.localizedDescription)", level: .error)
            }
            finishOperation(generation: generation)
        }
    }

    // MARK: - 事件与日志

    private func handle(_ event: WorkerEvent) {
        switch event {
        case .progress(let update):
            applyProgress(update)
        case .cleaning(let processed, let total, let path):
            // 海量文件删除时事件极其密集，这里再节流一次，避免主线程被刷新压垮
            let now = Date()
            guard processed == total || now.timeIntervalSince(lastProgressDate) >= 0.1 else { return }
            lastProgressDate = now
            progress = ProgressUpdate(phase: .cleaning, processed: processed, total: total, detail: "已处理 \(ByteFormatter.count(processed))/\(ByteFormatter.count(total))")
            logProgress(phase: .cleaning, detail: "删除 \(ByteFormatter.count(processed))/\(ByteFormatter.count(total)) \(path)")
        }
    }

    private func applyProgress(_ update: ProgressUpdate) {
        progress = update
        phase = update.phase
        if let startedAt {
            elapsed = Date().timeIntervalSince(startedAt)
        }
        logProgress(phase: update.phase, detail: update.detail)
    }

    private func resetLogThrottling() {
        lastLoggedPhase = .idle
        lastLogDate = .distantPast
        lastProgressDate = .distantPast
    }

    private func logProgress(phase: Phase, detail: String) {
        guard !detail.isEmpty else { return }
        let now = Date()
        guard phase != lastLoggedPhase || now.timeIntervalSince(lastLogDate) >= 0.6 else { return }
        lastLoggedPhase = phase
        lastLogDate = now
        appendLog("[\(phase.displayName)] \(detail)")
    }

    private func summarize(_ result: AnalysisResult) {
        appendLog(
            "扫描文件 \(ByteFormatter.count(result.totalFiles)) 个，总占用 \(ByteFormatter.string(result.totalBytes))",
            level: .success
        )
        appendLog(
            "重复组 \(ByteFormatter.count(result.duplicateGroupCount)) 组，冗余文件 \(ByteFormatter.count(result.redundantFileCount)) 个，可回收 \(ByteFormatter.string(result.reclaimableBytes))",
            level: result.duplicateGroupCount > 0 ? .success : .info
        )
        appendLog(
            "预估清理后：文件 \(ByteFormatter.count(result.filesAfterCleanup)) 个，占用 \(ByteFormatter.string(result.bytesAfterCleanup))",
            level: .info
        )
        if result.skippedFiles > 0 {
            appendLog("已跳过 \(ByteFormatter.count(result.skippedFiles)) 个条目（符号链接 / 空文件 / 低于最小体积）", level: .info)
        }
        if !result.inaccessibleDirectories.isEmpty {
            appendLog("无权限访问 \(result.inaccessibleDirectories.count) 个目录，已跳过", level: .warning)
        }
        if !result.unreadableFiles.isEmpty {
            appendLog("无法读取 \(result.unreadableFiles.count) 个文件，已跳过", level: .warning)
        }
        if hiddenGroupCount > 0 {
            appendLog("重复组过多，列表仅展示前 \(ByteFormatter.count(Self.maxRenderedGroups)) 组", level: .info)
        }
    }

    func appendLog(_ text: String, level: LogEntry.Level = .info) {
        logCounter += 1
        let entry = LogEntry(id: logCounter, time: Date(), level: level, text: text)
        logs.append(entry)
        if logs.count > Self.maxLogEntries {
            logs.removeFirst(logs.count - Self.maxLogEntries)
        }
    }

    private func startTimer() {
        stopTimer()
        // 使用非预调度定时器并显式加入 common 模式，
        // 避免同时被注册到 default + common 而重复触发。
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let startedAt = self.startedAt, self.isWorking else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension Phase {
    var displayName: String {
        switch self {
        case .idle: return "待机"
        case .scanning: return "扫描目录"
        case .groupingBySize: return "体积分组"
        case .partialHashing: return "快速校验"
        case .fullHashing: return "完整校验"
        case .completed: return "已完成"
        case .cleaning: return "清理中"
        case .cancelled: return "已取消"
        case .failed: return "失败"
        }
    }
}
