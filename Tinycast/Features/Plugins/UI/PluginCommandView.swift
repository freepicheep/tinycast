import SwiftUI

/// What a plugin command draws in the palette, with Tinycast's own rows and panes.
struct PluginCommandView: View {
    @Environment(\.metrics) private var metrics
    let plugins: PluginManager
    let rows: [PluginRow]
    let selection: Int
    let scroll: ScrollIntent
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void

    var body: some View {
        switch plugins.screen {
        case .idle, .launching:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            PluginFailureView(message: message, output: plugins.output)
        case .page(.detail(let detail)):
            PluginDetailPane(detail: detail, isPage: true)
        case .page(.list(let list)):
            listBody(list)
        }
    }

    @ViewBuilder
    private func listBody(_ list: PluginList) -> some View {
        if rows.isEmpty {
            if list.isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyResults(
                    text: list.emptyText ?? String(localized: "No Results"),
                    systemImage: list.emptySymbol ?? "magnifyingglass")
            }
        } else {
            let selected = rows.indices.contains(selection) ? rows[selection] : nil
            HStack(spacing: 0) {
                PluginRowList(rows: rows, selectedID: selected?.id, scroll: scroll,
                           isLoading: list.isLoading, onSelect: onSelect, onActivate: onActivate)
                if let detail = selected?.item.detail {
                    Divider()
                    PluginDetailPane(detail: detail, isPage: false)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct PluginRowList: View {
    @Environment(\.metrics) private var metrics
    let rows: [PluginRow]
    let selectedID: String?
    let scroll: ScrollIntent
    let isLoading: Bool
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if row.startsSection, let title = row.sectionTitle {
                            SectionHeader(title: title, isFirst: index == 0)
                        }
                        PluginItemRow(item: row.item, selected: row.id == selectedID)
                            .selectionFrame(row.id == selectedID)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onActivate(index) }
                            .onTapGesture { onSelect(index) }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID, atOrigin: selectedID != nil && selectedID == rows.first?.id,
                proxy: proxy)
        }
        .overlay(alignment: .top) {
            if isLoading { ProgressView().progressViewStyle(.linear).controlSize(.mini) }
        }
    }
}

private struct PluginItemRow: View {
    @Environment(\.metrics) private var metrics
    let item: PluginItem
    let selected: Bool
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            PluginIconView(icon: item.icon)
                .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            Text(item.title)
                .font(metrics.typography.rowTitle)
                .lineLimit(1)
                .layoutPriority(1)
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: metrics.spacing.md)
            ForEach(Array(item.badges.enumerated()), id: \.offset) { _, badge in
                Text(badge)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(fill))
        .armedHover($hovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PluginIconView: View {
    let icon: PluginIcon?

    var body: some View {
        switch icon {
        case .symbol(let name, let tint):
            IconTile(symbol: name, tint: tint.flatMap(IconTint.init(pluginName:)) ?? .gray)
        case .text(let text):
            Text(text).font(.system(size: 15)).lineLimit(1).minimumScaleFactor(0.5)
        case nil:
            IconTile(symbol: "circle.fill", tint: SettingsTab.plugins.tint)
        }
    }
}

extension IconTint {
    /// The kit's `Color` names, which are this enum's case names.
    init?(pluginName name: String) {
        let all: [String: IconTint] = [
            "gray": .gray, "blue": .blue, "cyan": .cyan, "mint": .mint, "green": .green,
            "yellow": .yellow, "orange": .orange, "red": .red, "pink": .pink, "purple": .purple,
            "indigo": .indigo, "brown": .brown
        ]
        guard let tint = all[name] else { return nil }
        self = tint
    }
}

/// A page of its own, or the pane beside the list for the selected row.
private struct PluginDetailPane: View {
    @Environment(\.metrics) private var metrics
    let detail: PluginDetail
    let isPage: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.spacing.md) {
                if isPage, let title = detail.title {
                    Text(title).font(.title3.weight(.semibold))
                }
                if detail.isLoading { ProgressView().controlSize(.small) }
                PluginMarkdownView(markdown: detail.markdown)
                if !detail.metadata.isEmpty {
                    Divider()
                    Grid(alignment: .leading, verticalSpacing: metrics.spacing.xs) {
                        ForEach(Array(detail.metadata.enumerated()), id: \.offset) { _, entry in
                            GridRow {
                                Text(entry.label).foregroundStyle(.secondary)
                                Text(entry.value).textSelection(.enabled)
                            }
                            .font(metrics.typography.rowTrailing)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(metrics.spacing.lg)
        }
        .thinScrollbar()
    }
}

/// A command that failed to compile or stopped: the error, and what it printed before.
private struct PluginFailureView: View {
    @Environment(\.metrics) private var metrics
    let message: String
    let output: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.spacing.md) {
                Label("The plugin stopped", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if !output.isEmpty {
                    Text("Output").font(.caption).foregroundStyle(.secondary)
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(metrics.spacing.lg)
        }
    }
}
