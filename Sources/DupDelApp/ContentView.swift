import DupDelCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                // 上方 1/4：配置区
                ConfigView(viewModel: viewModel)
                    .frame(height: max(190, proxy.size.height * 0.25))

                Divider()

                // 下方 3/4：结果统计 + 处理过程 + 状态栏
                VStack(spacing: 0) {
                    ResultBarView(viewModel: viewModel)
                        .frame(height: 58)
                    Divider()
                    ProcessingView(viewModel: viewModel)
                    Divider()
                    StatusBarView(viewModel: viewModel)
                        .frame(height: 34)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .onChange(of: viewModel.rootPath) { _, newValue in
            viewModel.rootPathDidChange(newValue)
        }
        .alert("出错了", isPresented: errorBinding) {
            Button("好") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .confirmationDialog("确认清理重复文件？", isPresented: $viewModel.showCleanConfirmation, titleVisibility: .visible) {
            Button("开始清理", role: .destructive) { viewModel.clean() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(cleanConfirmationMessage)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private var cleanConfirmationMessage: String {
        guard let analysis = viewModel.analysis else { return "" }
        return "将删除 \(ByteFormatter.count(analysis.redundantFileCount)) 个重复文件，每组仅保留创建/修改日期最新的一份，预计回收 \(ByteFormatter.string(analysis.reclaimableBytes))。"
    }
}

// MARK: - 配置区

struct ConfigView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("目录")
                    .font(.headline)
                TextField("粘贴目录路径或点击「选择」", text: $viewModel.rootPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.startAnalysis() }
                    .disabled(viewModel.isWorking)
                Button("选择…") { viewModel.chooseDirectory() }
                    .disabled(viewModel.isWorking)
                Button {
                    viewModel.revealInFinder()
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help("在 Finder 中打开")
                .disabled(viewModel.rootPath.isEmpty)
            }

            HStack(spacing: 16) {
                Toggle("包含隐藏文件", isOn: $viewModel.includeHiddenFiles)
                Toggle("忽略 0 字节文件", isOn: $viewModel.skipZeroLengthFiles)
                Toggle("清理后删除空目录", isOn: $viewModel.pruneEmptyDirectories)
                Toggle("删除前移到废纸篓", isOn: $viewModel.useTrash)
                HStack(spacing: 6) {
                    Text("最小体积(KB)")
                    TextField("", value: $viewModel.minimumSizeKB, format: .number)
                        .frame(width: 64)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 6) {
                    Text("并发")
                    Picker("", selection: $viewModel.concurrencyChoice) {
                        Text("自动").tag(0)
                        Text("2").tag(2)
                        Text("4").tag(4)
                        Text("8").tag(8)
                    }
                    .labelsHidden()
                    .frame(width: 88)
                }
            }
            .font(.subheadline)
            .toggleStyle(.checkbox)

            HStack(spacing: 10) {
                Button {
                    viewModel.startAnalysis()
                } label: {
                    Label("开始分析", systemImage: "magnifyingglass")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canAnalyse)

                Button {
                    viewModel.cancel()
                } label: {
                    Label("取消", systemImage: "stop.fill")
                }
                .disabled(!viewModel.isWorking)

                Spacer()

                Text(viewModel.analysis == nil ? "尚未分析" : "上次分析：\(ByteFormatter.count(viewModel.analysis?.totalFiles ?? 0)) 个文件")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

// MARK: - 结果统计条

struct ResultBarView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 18) {
            StatItem(title: "文件总数", value: ByteFormatter.count(viewModel.analysis?.totalFiles ?? 0), subtitle: ByteFormatter.string(viewModel.analysis?.totalBytes ?? 0))
            Divider().frame(height: 34)
            StatItem(
                title: "重复组 / 冗余文件",
                value: "\(ByteFormatter.count(viewModel.analysis?.duplicateGroupCount ?? 0)) / \(ByteFormatter.count(viewModel.analysis?.redundantFileCount ?? 0))",
                subtitle: "可回收 \(ByteFormatter.string(viewModel.analysis?.reclaimableBytes ?? 0))",
                highlight: true
            )
            Divider().frame(height: 34)
            StatItem(
                title: "清理后预估",
                value: ByteFormatter.count(viewModel.analysis?.filesAfterCleanup ?? 0),
                subtitle: ByteFormatter.string(viewModel.analysis?.bytesAfterCleanup ?? 0)
            )

            Spacer(minLength: 12)

            Button {
                viewModel.showCleanConfirmation = true
            } label: {
                Label("开始清理", systemImage: "trash.fill")
                    .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!viewModel.canClean)
            .help("删除重复文件，每组仅保留日期最新的一份")
        }
        .padding(.horizontal, 14)
    }
}

struct StatItem: View {
    let title: String
    let value: String
    let subtitle: String
    var highlight: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(highlight ? .orange : .primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 状态栏

struct StatusBarView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: viewModel.progressValue, total: 1.0)
                .progressViewStyle(.linear)
                .frame(width: 180)
            Text(viewModel.statusText)
                .font(.footnote)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let summary = viewModel.cleanSummary {
                Text("已删除 \(ByteFormatter.count(summary.deletedFiles)) 个文件 · 回收 \(ByteFormatter.string(summary.reclaimedBytes))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("耗时 \(String(format: "%.1f", viewModel.elapsed))s")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
    }
}
