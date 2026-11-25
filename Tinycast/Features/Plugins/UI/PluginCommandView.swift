import SwiftUI

/// What the palette shows for a running command: the launch, a failure, or the last frame.
struct PluginCommandView: View {
    let layout: PluginScreenLayout
    let state: PluginHost.State
    let selection: Int
    let scroll: ScrollIntent
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void
    let onActions: (Int) -> Void
    let onSet: (String, PluginFieldValue) -> Void
    let onSubmit: () -> Void

    var body: some View {
        switch state {
        case .idle, .launching:
            Color.clear
        case .failed(let message):
            EmptyResults(
                text: String(localized: "The command stopped"), detail: message,
                systemImage: "exclamationmark.triangle")
        case .rendered(let frame):
            screen(frame.screen)
        }
    }

    @ViewBuilder
    private func screen(_ screen: PluginScreen) -> some View {
        switch screen {
        case .list(let list):
            PluginListView(
                layout: layout, isLoading: list.chrome.isLoading, showsDetail: list.showsDetail,
                selection: selection, scroll: scroll, onSelect: onSelect, onActivate: onActivate,
                onActions: onActions)
        case .grid(let grid):
            PluginGridView(
                layout: layout, grid: grid, selection: selection, scroll: scroll, onSelect: onSelect,
                onActivate: onActivate, onActions: onActions)
        case .detail(let detail):
            PluginDetailView(detail: detail, stacksMetadata: false)
        case .form(let form):
            PluginFormView(
                form: form, layout: layout, selection: selection, scroll: scroll, onSelect: onSelect, onSet: onSet,
                onSubmit: onSubmit)
        case .menuBar:
            EmptyResults(
                text: String(localized: "This command runs in the menu bar"), systemImage: "menubar.rectangle")
        case .unsupported(let kind):
            EmptyResults(
                text: String(localized: "This version of Tinycast can't show this screen"), detail: kind,
                systemImage: "questionmark.square.dashed")
        }
    }
}

// MARK: - Empty and loading

private struct PluginEmptyView: View {
    @Environment(\.metrics) private var metrics
    let layout: PluginScreenLayout
    let isLoading: Bool

    var body: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let empty = layout.emptyState {
            VStack(spacing: metrics.spacing.md) {
                if let icon = empty.icon { PluginImageView(image: icon, size: 42) }
                Text(empty.title).font(metrics.typography.rowTitle)
                if let description = empty.description {
                    Text(description)
                        .font(metrics.typography.rowTrailing)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, metrics.spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyResults(text: String(localized: "No results"))
        }
    }
}

// MARK: - List

private struct PluginListView: View {
    @Environment(\.metrics) private var metrics
    let layout: PluginScreenLayout
    let isLoading: Bool
    let showsDetail: Bool
    let selection: Int
    let scroll: ScrollIntent
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void
    let onActions: (Int) -> Void

    private static let detailListWidth: CGFloat = 290

    var body: some View {
        if layout.items.isEmpty {
            PluginEmptyView(layout: layout, isLoading: isLoading)
        } else if showsDetail {
            HStack(spacing: 0) {
                rows.frame(width: metrics.scaled(Self.detailListWidth))
                Rectangle().fill(Theme.Colors.separator).frame(width: 1)
                if let detail = selectedRow?.detail {
                    PluginDetailView(detail: detail, stacksMetadata: true)
                } else {
                    Color.clear
                }
            }
        } else {
            rows
        }
    }

    private var selectedRow: PluginRow? {
        layout.items.indices.contains(selection) ? layout.items[selection].row : nil
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(layout.sections) { section in
                        if let title = section.title, !title.isEmpty {
                            SectionHeader(
                                title: [title, section.subtitle].compactMap { $0 }.filter { !$0.isEmpty }
                                    .joined(separator: "  ·  "),
                                isFirst: section.id == layout.sections.first?.id)
                        }
                        ForEach(section.items) { item in
                            if let row = item.row {
                                PluginRowView(row: row, selected: item.index == selection, compact: showsDetail)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        onSelect(item.index)
                                        onActivate(item.index)
                                    }
                                    .onRightClick { onActions(item.index) }
                                    .selectionFrame(item.index == selection)
                            }
                        }
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
            .scrollFollowsSelection(scroll, row: selectedID, atOrigin: selection == 0, proxy: proxy)
        }
    }

    private var selectedID: String? {
        layout.items.indices.contains(selection) ? layout.items[selection].id : nil
    }
}

private struct PluginRowView: View {
    @Environment(\.metrics) private var metrics
    let row: PluginRow
    let selected: Bool
    let compact: Bool
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            if let icon = row.icon {
                PluginImageView(image: icon, size: metrics.size.resultRowIcon)
            }
            PluginTextView(text: row.title)
                .font(metrics.typography.rowTitle)
                .lineLimit(1)
                .layoutPriority(1)
            if !compact, let subtitle = row.subtitle {
                PluginTextView(text: subtitle, defaultColor: Theme.Colors.textSecondary)
                    .font(metrics.typography.rowTrailing)
                    .lineLimit(1)
            }
            Spacer(minLength: metrics.spacing.sm)
            if !row.accessories.isEmpty {
                PluginAccessoriesView(accessories: row.accessories)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .redacted(reason: row.isRedacted ? .placeholder : [])
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(fill))
        .armedHover($hovered)
    }
}

/// What a row shows at its trailing edge.
struct PluginAccessoriesView: View {
    @Environment(\.metrics) private var metrics
    let accessories: [PluginAccessory]

    var body: some View {
        HStack(spacing: metrics.spacing.md) {
            ForEach(Array(accessories.enumerated()), id: \.offset) { _, accessory in
                view(accessory)
            }
        }
        .font(metrics.typography.rowTrailing)
    }

    @ViewBuilder
    private func view(_ accessory: PluginAccessory) -> some View {
        switch accessory {
        case .text(let text):
            PluginTextView(text: text, defaultColor: Theme.Colors.textSecondary).lineLimit(1)
        case .count(let count):
            Text(count, format: .number)
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.horizontal, metrics.spacing.sm)
                .background(Capsule().fill(Theme.Colors.textSecondary.opacity(0.14)))
        case .label(let text, let icon):
            HStack(spacing: metrics.spacing.xs) {
                PluginImageView(image: icon, size: 13)
                PluginTextView(text: text, defaultColor: Theme.Colors.textSecondary).lineLimit(1)
            }
        case .icon(let icon, let tooltip):
            PluginImageView(image: icon, size: 14).help(tooltip ?? "")
        case .tag(let text, let color):
            PluginTagView(text: text, color: color)
        case .unsupported:
            EmptyView()
        }
    }
}

struct PluginTagView: View {
    @Environment(\.metrics) private var metrics
    let text: String
    let color: PluginColor?

    var body: some View {
        let tint = color.map(PluginColors.color) ?? Theme.Colors.textSecondary
        Text(text)
            .font(metrics.typography.rowTrailing)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, metrics.spacing.xs)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(0.16)))
    }
}

/// A plugin's text: plain words or a date, in its colour and weight.
struct PluginTextView: View {
    let text: PluginText
    var defaultColor: Color?

    var body: some View {
        content
            .fontWeight(text.isBold ? .semibold : nil)
            .monospaced(text.isMonospaced)
            .foregroundStyle(text.color.map(PluginColors.color) ?? defaultColor ?? Theme.Colors.textPrimary)
    }

    @ViewBuilder
    private var content: some View {
        switch text.content {
        case .plain(let words):
            Text(words)
        case .date(let seconds, let style):
            let date = Date(timeIntervalSince1970: seconds)
            switch style {
            case .relative: Text(date, format: .relative(presentation: .named))
            case .offset: Text(date, style: .offset)
            case .timer: Text(date, style: .timer)
            case .date: Text(date, style: .date)
            case .time: Text(date, style: .time)
            }
        case .unsupported:
            Text(verbatim: "")
        }
    }
}

// MARK: - Grid

private struct PluginGridView: View {
    @Environment(\.metrics) private var metrics
    let layout: PluginScreenLayout
    let grid: PluginGridScreen
    let selection: Int
    let scroll: ScrollIntent
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void
    let onActions: (Int) -> Void

    var body: some View {
        if layout.items.isEmpty {
            PluginEmptyView(layout: layout, isLoading: grid.chrome.isLoading)
        } else {
            // Measured once for the whole grid: a tile's own reader would cost a pass per cell.
            GeometryReader { geometry in
                let columns = max(grid.columns, 1)
                let spacing = metrics.spacing.sm
                let width = (geometry.size.width - metrics.spacing.md * 2 - spacing * CGFloat(columns - 1))
                    / CGFloat(columns)
                tiles(width: max(width, 1), columns: columns)
            }
        }
    }

    private func tiles(width: CGFloat, columns: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: metrics.spacing.sm) {
                    ForEach(layout.sections) { section in
                        if let title = section.title, !title.isEmpty {
                            SectionHeader(title: title, isFirst: section.id == layout.sections.first?.id)
                        }
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: metrics.spacing.sm), count: columns),
                            spacing: metrics.spacing.sm
                        ) {
                            ForEach(section.items) { item in
                                if let row = item.row {
                                    PluginTileView(
                                        row: row, grid: grid, width: width, selected: item.index == selection
                                    )
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        onSelect(item.index)
                                        onActivate(item.index)
                                    }
                                    .onRightClick { onActions(item.index) }
                                    .selectionFrame(item.index == selection)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.vertical, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(scroll, row: selectedID, atOrigin: selection < columns, proxy: proxy)
        }
    }

    private var selectedID: String? {
        layout.items.indices.contains(selection) ? layout.items[selection].id : nil
    }
}

private struct PluginTileView: View {
    @Environment(\.metrics) private var metrics
    let row: PluginRow
    let grid: PluginGridScreen
    let width: CGFloat
    let selected: Bool
    @State private var hovered = false

    private static let radius: CGFloat = 10

    private var height: CGFloat { width / max(grid.aspectRatio, 0.1) }

    private var inset: CGFloat {
        switch grid.inset {
        case .none: 0
        case .small: width * 0.08
        case .medium: width * 0.16
        case .large: width * 0.24
        }
    }

    var body: some View {
        VStack(spacing: metrics.spacing.xs) {
            tile
            PluginTextView(text: row.title)
                .font(metrics.typography.rowTrailing)
                .lineLimit(1)
            if let subtitle = row.subtitle {
                PluginTextView(text: subtitle, defaultColor: Theme.Colors.textSecondary)
                    .font(metrics.typography.rowTrailing)
                    .lineLimit(1)
            }
        }
        .frame(width: width)
        .redacted(reason: row.isRedacted ? .placeholder : [])
        .armedHover($hovered)
    }

    private var tile: some View {
        let side = min(width, height) - inset * 2
        return content(size: max(side, 1))
            .frame(width: width - inset * 2, height: height - inset * 2)
            .clipShape(RoundedRectangle(cornerRadius: Self.radius - 2, style: .continuous))
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(selected ? Theme.Colors.selection : hovered ? Theme.Colors.rowHover : Theme.Colors.cardFill))
    }

    @ViewBuilder
    private func content(size: CGFloat) -> some View {
        switch row.content ?? row.icon {
        case .color(let color)?:
            Rectangle().fill(PluginColors.color(color))
        case .remote(let url, _)?:
            AsyncImage(url: URL(string: url)) { phase in
                if let image = phase.image {
                    if grid.fit == .fill {
                        image.resizable().scaledToFill()
                    } else {
                        image.resizable().scaledToFit()
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        case let image?:
            PluginImageView(image: image, size: size)
        case nil:
            Color.clear
        }
    }
}

// MARK: - Detail

/// A detail screen, or the pane a list shows beside its rows; the pane is too narrow for a sidebar.
struct PluginDetailView: View {
    @Environment(\.metrics) private var metrics
    let detail: PluginDetailScreen
    let stacksMetadata: Bool

    private static let metadataWidth: CGFloat = 240

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.spacing.md) {
                    if detail.chrome.isLoading && detail.markdown.isEmpty {
                        ProgressView().controlSize(.small)
                    }
                    if !detail.markdown.isEmpty {
                        MarkdownView(blocks: MarkdownBlock.parse(detail.markdown))
                            .textSelection(.enabled)
                    }
                    if stacksMetadata, !detail.metadata.isEmpty {
                        PluginMetadataView(items: detail.metadata)
                            .padding(.top, detail.markdown.isEmpty ? 0 : metrics.spacing.xxl)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, metrics.spacing.lg)
                .padding(.vertical, metrics.spacing.md)
                .hideNativeScrollers()
            }
            .edgeDissolve()
            .thinScrollbar()
            if !stacksMetadata, !detail.metadata.isEmpty {
                Rectangle().fill(Theme.Colors.separator).frame(width: 1)
                ScrollView {
                    PluginMetadataView(items: detail.metadata)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, metrics.spacing.lg)
                        .padding(.vertical, metrics.spacing.md)
                        .hideNativeScrollers()
                }
                .frame(width: metrics.scaled(Self.metadataWidth))
                .edgeDissolve()
                .thinScrollbar()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PluginMetadataView: View {
    @Environment(\.metrics) private var metrics
    let items: [PluginMetadataItem]

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.lg) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .label(let title, let text, let icon):
                    entry(title) {
                        HStack(spacing: metrics.spacing.xs) {
                            if let icon { PluginImageView(image: icon, size: 14) }
                            PluginTextView(text: text).textSelection(.enabled)
                        }
                    }
                case .link(let title, let text, let url):
                    entry(title) {
                        if let destination = URL(string: url) {
                            Link(text, destination: destination)
                        } else {
                            Text(text)
                        }
                    }
                case .tags(let title, let tags):
                    entry(title) {
                        HStack(spacing: metrics.spacing.xs) {
                            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                                PluginTagView(text: tag.text, color: tag.color)
                            }
                        }
                    }
                case .separator:
                    Rectangle().fill(Theme.Colors.separator).frame(height: 1)
                case .unsupported:
                    EmptyView()
                }
            }
        }
    }

    private func entry(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: metrics.spacing.xs) {
            Text(title)
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textSecondary)
            content().font(metrics.typography.rowTitle)
        }
    }
}
