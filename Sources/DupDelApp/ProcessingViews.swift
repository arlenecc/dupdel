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
                    DuplicateGroupRow(group: group)
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

    var body: some View {
        DisclosureGroup {
            ForEach(group.files, id: \.url) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.url == group.keeper.url ? "checkmark.seal.fill" : "trash")
                        .foregroundStyle(entry.url == group.keeper.url ? .green : .secondary)
                        .frame(width: 16)
                    Text(entry.url.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(entry.url == group.keeper.url ? "保留（最新）" : Self.dateString(entry.recency))
                        .font(.caption)
                        .foregroundStyle(entry.url == group.keeper.url ? .green : .secondary)
                }
                .padding(.leading, 18)
            }
        } label: {
            HStack(spacing: 10) {
                Text("\(group.files.count) 份")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .frame(width: 56, alignment: .leading)
                Text("单份 \(ByteFormatter.string(group.fileSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("可回收 \(ByteFormatter.string(group.reclaimableBytes))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func dateString(_ date: Date) -> String {
        formatter.string(from: date)
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
