import SwiftUI

/// The toolbar's picker beside the search field, stating the option it holds.
struct PluginToolbarPickerButton: View {
    /// Room for a long option beside its icon and tick.
    static let listWidth: CGFloat = 240

    let picker: PluginPicker
    let isOpen: Bool
    let action: () -> Void

    private var chosen: PluginOption? {
        picker.selection.flatMap { picker.options.indices.contains($0) ? picker.options[$0] : nil }
    }

    var body: some View {
        HeaderMenuButton(
            title: chosen?.title ?? picker.title,
            icon: chosen?.icon.map(PluginCommandScreen.menuIcon) ?? .blank,
            isOpen: isOpen, help: "\(picker.title)  ⌘P", action: action)
    }
}

/// What ties the palette to the command: the query to its search binding, and the highlighted row
/// to its selection binding, both sent once per change.
struct PluginPaletteBindings: ViewModifier {
    let layout: PluginScreenLayout
    let selection: Int
    let host: PluginHost
    @Environment(PaletteState.self) private var palette
    @State private var sentSelection: String?

    private var searchBinding: String? { layout.chrome?.search?.binding }

    private var selectedRowID: String? {
        layout.items.indices.contains(selection) ? layout.items[selection].row?.id : nil
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: palette.query) { _, query in
                if searchBinding != nil { host.search(query) }
            }
            // Anything typed while the command was starting predates its binding.
            .onChange(of: searchBinding) { previous, binding in
                guard previous == nil, binding != nil, !palette.query.isEmpty else { return }
                host.search(palette.query)
            }
            .onChange(of: selectedRowID, initial: true) { _, id in
                guard let binding = layout.selectionBinding, let id, id != sentSelection else { return }
                sentSelection = id
                host.set(binding, .text(id))
            }
            // The plugin moved its selection: the palette follows it.
            .onChange(of: layout.requestedSelection) { _, requested in
                guard let requested, requested != selection else { return }
                palette.selection = requested
            }
    }
}

/// An action's own shortcut, matched before the palette's bindings see it.
struct PluginShortcutKeys: ViewModifier {
    /// Resolved per press: SwiftUI keeps stale key handlers, and a captured screen keeps its rows.
    let screen: () -> PluginCommandScreen?
    let selection: Int

    func body(content: Content) -> some View {
        content.onKeyPress(phases: .down) { press in
            guard !press.modifiers.isEmpty, let screen = screen() else { return .ignored }
            return screen.dispatchShortcut(
                key: ASCIIKeyboardLayout.keyEquivalent(fallingBackTo: press.key), modifiers: press.modifiers,
                at: selection) ? .handled : .ignored
        }
    }
}

/// The command's toasts, in the footer's place while one shows.
struct PluginToastSlot: ViewModifier {
    @Environment(\.metrics) private var metrics
    let host: PluginHost
    let showing: Bool

    func body(content: Content) -> some View {
        let toast = showing ? host.toasts.last : nil
        ZStack(alignment: .leading) {
            content
                .opacity(toast == nil ? 1 : 0)
                .allowsHitTesting(toast == nil)
            if let toast {
                PluginToastPill(
                    toast: toast.content, onAction: { host.runToastAction(token: $0) },
                    onDismiss: { host.hide(toast: toast.id) }
                )
                .padding(.trailing, metrics.spacing.md)
                .id(toast.id)
                .transition(.scale(scale: 0.5, anchor: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: toast?.id)
    }
}

private struct PluginToastPill: View {
    private static let glowOpacity = 0.14
    private static let glowRadius: CGFloat = 150
    private static let rimOpacity = 0.25

    @Environment(\.metrics) private var metrics
    let toast: PluginToast
    let onAction: (String) -> Void
    let onDismiss: () -> Void
    @State private var hovered = false
    /// A fresh stamp re-arms the reset, so a second copy holds "Copied".
    @State private var copiedAt: Date?

    private var tint: Color {
        switch toast.style {
        case .success: Theme.Colors.success
        case .failure: Theme.Colors.destructive
        case .animated: Theme.Colors.progress
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            mark.frame(width: metrics.size.menuButton, height: metrics.size.menuButton)
            HStack(spacing: metrics.spacing.md) {
                Text(toast.title).foregroundStyle(Theme.Colors.textPrimary).layoutPriority(1)
                if let message = toast.message, !message.isEmpty {
                    Text(message).foregroundStyle(Theme.Colors.textSecondary)
                }
                if toast.style == .failure {
                    divider
                    button {
                        Paster.copyPlainText([toast.title, toast.message].compactMap(\.self).joined(separator: "\n"))
                        copiedAt = Date()
                    } label: {
                        // The wider word holds the width, so the pill never twitches on copy.
                        ZStack {
                            Text("Copied").hidden()
                            Text(copiedAt == nil ? "Copy" : "Copied")
                        }
                    }
                } else if let title = toast.actionTitle, let token = toast.actionToken {
                    divider
                    button { onAction(token) } label: { Text(title) }
                }
            }
            .font(metrics.typography.bar)
            .lineLimit(1)
            .padding(.trailing, metrics.spacing.xl)
        }
        .frame(height: metrics.size.menuButton)
        .background { glow }
        .overlay {
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [tint.opacity(Self.rimOpacity), tint.opacity(0.06), .clear],
                    startPoint: .leading, endPoint: .trailing),
                lineWidth: Theme.Size.hairline)
        }
        .frosted(in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: onDismiss)
        .onHover { isHovered in
            withAnimation(.easeOut(duration: Theme.Duration.hover)) { hovered = isHovered }
        }
        .accessibilityAction(named: "Dismiss", onDismiss)
        .task(id: copiedAt) {
            guard copiedAt != nil else { return }
            try? await Task.sleep(for: .seconds(Theme.Duration.copyFeedback))
            copiedAt = nil
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Colors.border)
            .frame(width: Theme.Size.hairline, height: metrics.size.menuIcon * 0.7)
    }

    private func button(action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action, label: label)
            .fixedSize()
            .buttonStyle(.plain)
            .fontWeight(.semibold)
            .foregroundStyle(Theme.Colors.textPrimary)
    }

    private var glow: some View {
        GeometryReader { proxy in
            Capsule().fill(
                RadialGradient(
                    colors: [tint.opacity(Self.glowOpacity), tint.opacity(0.03), .clear],
                    center: UnitPoint(x: metrics.size.menuButton / 2 / proxy.size.width, y: 0.5),
                    startRadius: 0, endRadius: Self.glowRadius))
        }
    }

    private var mark: some View {
        Group {
            if hovered {
                Image(systemName: "xmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.Colors.textSecondary)
            } else {
                symbol.foregroundStyle(tint)
            }
        }
        .font(metrics.typography.menuIcon)
        .transition(.opacity)
    }

    @ViewBuilder
    private var symbol: some View {
        switch toast.style {
        case .success: Image(systemName: "checkmark")
        case .failure: Image(systemName: "exclamationmark")
        case .animated:
            Image(systemName: "progress.indicator")
                .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing)
        }
    }
}
