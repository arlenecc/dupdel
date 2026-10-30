import DupDelCore
import SwiftUI

/// 处理过程显示区域：上半部分重复文件清单，下半部分处理日志。
struct ProcessingView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                DuplicateGroupsView(viewModel: viewModel)
                    .frame(height: max(120, proxy.size.height * 0.58))
                Divider()
                LogView(viewModel: viewModel)
            }
        }
    }
}

struct DuplicateGroupsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("重复文件清单")
                    .font(.headline)
                Text("\(ByteFormatter.count(viewModel.analysis?.duplicateGroupCount ?? 0)) 组")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if viewModel.hiddenGroupCount > 0 {
                    Text("[列表仅展示前 \(ByteFormatter.count(AppViewModel.maxRenderedGroups)) 组]")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if viewModel.analysis == nil {
                    Text("分析后在此查看重复文件")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            List {
                ForEach(viewModel.displayedGroups) { group in
                    DuplicateGroupRow(group: group, viewModel: viewModel)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if let analysis = viewModel.analysis, analysis.groups.isEmpty {
                    ContentUnavailableView {
                        Label("没有发现重复文件", systemImage: "checkmark.circle")
                    } description: {
                        Text("该目录下所有文件内容都是唯一的")
                    }
                }
            }
        }
    }
}

struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        DisclosureGroup {
            ForEach(group.files, id: \.url) { entry in
                let isKeeper = entry.url == group.keeper.url
                DuplicateFileRow(
                    entry: entry,
                    isKeeper: isKeeper,
                    isManual: group.isKeeperManual,
                    groupSize: group.fileSize
                ) {
                    isKeeper ? viewModel.resetKeeper(for: group) : viewModel.selectKeeper(entry.url, for: group)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text("\(group.files.count) 份")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .frame(width: 56, alignment: .leading)
                Text("单份 \(ByteFormatter.string(group.fileSize))（\(Self.exactBytes(group.fileSize)) 字节）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if group.isKeeperManual {
                    Text("已手动指定保留")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                Spacer()
                Text("可回收 \(ByteFormatter.string(group.reclaimableBytes))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 带千分位的精确字节数，用于确认「被判定为重复的这些文件体积确实一样」。
    static func exactBytes(_ bytes: UInt64) -> String {
        ByteFormatter.count(Int(bytes))
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func dateString(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

/// 组内单份副本：路径 + 精确体积 + 保留/时间。
/// 体积与组不一致时标为橙色——正常情况下不该出现，出现说明文件在分析期间被改动，应重新分析。
struct DuplicateFileRow: View {
    let entry: FileEntry
    let isKeeper: Bool
    let isManual: Bool
    let groupSize: UInt64
    /// 点击图标：独占保留者时切到这一份；已是保留者时恢复自动选择。
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: isKeeper ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(isKeeper ? Color.green : Color.secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(isKeeper ? "点击恢复自动选择（保留最新）" : "点击改为保留这一份")
            Text(entry.url.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(DuplicateGroupRow.exactBytes(entry.size))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(entry.size == groupSize ? Color.secondary : Color.orange)
                .help(ByteFormatter.string(entry.size))
                .frame(minWidth: 88, alignment: .trailing)
            Text(isKeeper ? (isManual ? "保留（手动）" : "保留（最新）") : DuplicateGroupRow.dateString(entry.recency))
                .font(.caption)
                .foregroundStyle(isKeeper ? Color.green : Color.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.leading, 18)
    }
}

struct LogView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("处理过程")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.logs.count) 条")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.logs) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(Self.timeString(entry.time))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(entry.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Self.color(entry.level))
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }
                .onChange(of: viewModel.logs.count) { _, _ in
                    if let last = viewModel.logs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func timeString(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static func color(_ level: AppViewModel.LogEntry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
