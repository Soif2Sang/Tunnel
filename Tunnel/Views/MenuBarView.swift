import SwiftUI

/// Single-popover root view. Manages a screen stack internally so the entire
/// app lives inside the status item popover.
struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @State private var screen: Screen = .list
    @State private var expandedID: UUID?

    enum Screen: Equatable {
        case list
        case addSearch
        case addConfigure(KubeService)
        case addManual
        case editForward(UUID)
        case settings
        case importing
    }

    var body: some View {
        VStack(spacing: 0) {
            switch screen {
            case .list:        ListScreen(screen: $screen, expandedID: $expandedID)
            case .addSearch:   AddSearchScreen(screen: $screen)
            case .addConfigure(let svc): AddConfigureScreen(service: svc, screen: $screen)
            case .addManual:   AddManualScreen(screen: $screen)
            case .editForward(let id): EditForwardScreen(forwardID: id, screen: $screen)
            case .settings:    SettingsScreen(screen: $screen)
            case .importing:   ImportScreen(screen: $screen)
            }
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .task {
            // First-run import prompt
            if app.hasBootstrapped, app.forwards.isEmpty, !app.hasImportedZshrc {
                let imports = app.loadZshrcImports()
                if imports.contains(where: { $0.parsed != nil }) {
                    screen = .importing
                }
            }
        }
    }
}

// MARK: - Reusable header bar

private struct ScreenHeader<Leading: View, Trailing: View>: View {
    let title: String
    let leading: Leading
    let trailing: Trailing

    init(
        title: String,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            leading
            Text(title).font(.headline)
            Spacer()
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Standard leading content: an app icon (no action). Use on root screens.
private struct HomeIcon: View {
    var body: some View {
        Image(systemName: "point.3.connected.trianglepath.dotted")
            .foregroundStyle(.secondary)
    }
}

/// Standard leading content: a back chevron that runs the action.
private struct BackButton: View {
    let action: () -> Void
    @State private var isHovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.primary.opacity(isHovered ? 0.10 : 0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Back")
    }
}

/// Round soft-button for header icons (settings, refresh, etc).
private struct HeaderIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.primary.opacity(isHovered ? 0.12 : 0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// Square soft-button used in expanded detail rows. Generous hitbox + hover affordance.
private struct IconButton: View {
    let systemImage: String
    let help: String
    var destructive: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(destructive && isHovered ? Color.red : .secondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill((destructive ? Color.red : Color.primary)
                            .opacity(isHovered ? 0.12 : 0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

// MARK: - List screen (saved forwards)

private struct ListScreen: View {
    @Environment(AppState.self) private var app
    @Binding var screen: MenuBarView.Screen
    @Binding var expandedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Brand
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 24, height: 24)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Tunnel")
                .font(.system(size: 15, weight: .semibold, design: .default))
                .tracking(-0.2)

            Spacer()

            statusBadge

            HeaderIconButton(systemImage: "gearshape", help: "Settings") {
                screen = .settings
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(headerDivider, alignment: .bottom)
    }

    private var headerDivider: some View {
        Rectangle().fill(.primary.opacity(0.07)).frame(height: 0.5)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let s = app.currentSummary()
        if s.runningCount == 0 && s.failedCount == 0 {
            EmptyView()
        } else {
            HStack(spacing: 5) {
                Circle()
                    .fill(badgeColor(s.tone))
                    .frame(width: 6, height: 6)
                    .shadow(color: badgeColor(s.tone).opacity(0.6), radius: 2.5)
                Text(s.failedCount > 0 ? "\(s.runningCount) up · \(s.failedCount) failed" : "\(s.runningCount) running")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.primary.opacity(0.06), in: Capsule())
        }
    }

    private func badgeColor(_ tone: AppState.StatusTone) -> Color {
        switch tone {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .grey: return .secondary
        }
    }

    @ViewBuilder
    private var content: some View {
        if app.forwards.isEmpty {
            EmptyStateView { screen = .addSearch }
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(app.forwards) { fw in
                        ForwardRow(
                            forward: fw,
                            state: app.states[fw.id] ?? .idle,
                            isExpanded: expandedID == fw.id,
                            onToggleExpand: {
                                // Instant expand/collapse — no SwiftUI animation here.
                                // The popover (animates = false) resizes in the same
                                // frame, so the user sees one coherent change instead
                                // of two unsynchronised animations.
                                expandedID = expandedID == fw.id ? nil : fw.id
                            },
                            onEdit: { screen = .editForward(fw.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 460)
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button {
                screen = .addSearch
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("Add forward").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                        startPoint: .top, endPoint: .bottom),
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: Color.accentColor.opacity(0.25), radius: 4, y: 1)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(headerDivider, alignment: .top)
    }
}

// MARK: - Manual entry CTA (banner)

private struct ManualEntryCTA: View {
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.accentColor.opacity(0.7), Color.accentColor.opacity(0.45)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 28, height: 28)
                    Image(systemName: "keyboard")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Enter manually")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Type namespace + service directly")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.primary.opacity(isHovered ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .help("Type namespace and service directly — works without cluster-wide list permission")
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: 56, height: 56)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(spacing: 3) {
                Text("No forwards yet")
                    .font(.system(size: 14, weight: .semibold))
                Text("Add a kubectl port-forward to get started")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Button(action: onAdd) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("Add your first forward").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(
                    LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

// MARK: - Forward row (with optional expanded detail)

private struct ForwardRow: View {
    @Environment(AppState.self) private var app
    let forward: PortForward
    let state: SessionState
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onEdit: () -> Void

    @State private var isHovered = false
    @State private var isActionHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // Header (always visible, click to expand)
            HStack(spacing: 10) {
                accentBar
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(forward.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if state.isRunning {
                            Text("LIVE")
                                .font(.system(size: 8, weight: .black))
                                .tracking(0.6)
                                .foregroundStyle(.green)
                                .padding(.horizontal, 4).padding(.vertical, 1.5)
                                .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    Text("\(shortContext(forward.context)) · \(forward.namespace) / \(forward.serviceName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                portPill
                actionButton
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .onTapGesture { onToggleExpand() }
            .onHover { isHovered = $0 }

            if isExpanded {
                ExpandedDetail(forward: forward, state: state, onEdit: onEdit)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .padding(.top, 2)
            }
        }
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
    }

    private var accentBar: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(stateColor)
            .frame(width: 3, height: 28)
            .opacity(state.isActive || state.isFailed ? 1 : 0.25)
            .shadow(color: state.isRunning ? .green.opacity(0.5) : .clear, radius: 3)
    }

    private var stateColor: Color {
        switch state {
        case .running: return .green
        case .connecting: return .yellow
        case .reconnecting: return .orange
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    private var portPill: some View {
        HStack(spacing: 4) {
            Text("\(forward.localPort)").monospacedDigit()
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("\(forward.remotePort)").monospacedDigit()
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var actionButton: some View {
        Button {
            Task {
                if state.isActive { await app.stop(id: forward.id) }
                else { await app.start(forward: forward) }
            }
        } label: {
            Image(systemName: state.isActive ? "stop.fill" : "play.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(state.isActive ? .red : .green)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill((state.isActive ? Color.red : Color.green)
                        .opacity(isActionHovered ? 0.18 : 0.10))
                )
                .overlay(
                    Circle().strokeBorder((state.isActive ? Color.red : Color.green).opacity(0.25), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { isActionHovered = $0 }
        .help(state.isActive ? "Stop" : "Start")
    }

    private var rowBackground: some View {
        Group {
            if state.isRunning {
                Color.green.opacity(isHovered ? 0.10 : 0.06)
            } else if state.isFailed {
                Color.red.opacity(isHovered ? 0.10 : 0.06)
            } else if isHovered || isExpanded {
                Color.primary.opacity(0.05)
            } else {
                Color.clear
            }
        }
    }

    private var borderColor: Color {
        if state.isRunning { return .green.opacity(0.20) }
        if state.isFailed  { return .red.opacity(0.20) }
        if isExpanded      { return .primary.opacity(0.10) }
        return .clear
    }

    /// Strip the `oidc@` prefix for compactness — `oidc@sparteo` → `sparteo`.
    private func shortContext(_ ctx: String) -> String {
        if let at = ctx.firstIndex(of: "@") {
            return String(ctx[ctx.index(after: at)...])
        }
        return ctx
    }
}

private struct ExpandedDetail: View {
    @Environment(AppState.self) private var app
    let forward: PortForward
    let state: SessionState
    let onEdit: () -> Void

    @State private var portHolder: PortHolder?
    @State private var isFreeing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.4)
            statusLine
            if case .failed(.localPortInUse(let port)) = state {
                portConflictPanel(port: port)
                    .padding(.leading, 11)
            }
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { forward.autoStart },
                    set: { v in Task { await app.setAutoStart(id: forward.id, v) } }
                )) {
                    Text("Auto-start at launch")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                Spacer()
                IconButton(systemImage: "pencil", help: "Edit forward", action: onEdit)
                IconButton(systemImage: "trash", help: "Delete forward", destructive: true) {
                    Task { await app.delete(id: forward.id) }
                }
            }
            .padding(.leading, 11) // align with content past accent bar
            if let lines = app.liveLogs[forward.id], !lines.isEmpty {
                logsView(lines)
                    .padding(.leading, 11)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        let baseFont = Font.system(size: 11, weight: .medium)
        let pillStyle: AnyShapeStyle = AnyShapeStyle(.primary.opacity(0.05))
        switch state {
        case .idle:
            statusPill("Idle", icon: "circle.dashed", color: .secondary, base: baseFont, bg: pillStyle)
        case .connecting:
            statusPill("Connecting…", icon: "ellipsis.circle", color: .yellow, base: baseFont, bg: pillStyle)
        case .running(let since, let binding):
            statusPill("\(binding) · since \(since.formatted(date: .omitted, time: .shortened))",
                       icon: "circle.fill", color: .green, base: baseFont, bg: pillStyle)
        case .reconnecting(let attempt, let nextAt, let lastError):
            VStack(alignment: .leading, spacing: 4) {
                statusPill("Reconnecting (#\(attempt)) · next \(nextAt.formatted(date: .omitted, time: .standard))",
                           icon: "arrow.clockwise", color: .orange, base: baseFont, bg: pillStyle)
                if !lastError.isEmpty {
                    Text(lastError)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.leading, 11)
                }
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    statusPill("Failed", icon: "exclamationmark.triangle.fill", color: .red, base: baseFont, bg: pillStyle)
                    Spacer()
                    Button {
                        Task { await app.acknowledgeFailure(id: forward.id) }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            Text("Dismiss").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.primary.opacity(0.06), in: Capsule())
                        .overlay(Capsule().strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Acknowledge the error and reset to idle")
                    .padding(.trailing, 11)
                }
                Text(reason.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.leading, 11)
            }
        }
    }

    @ViewBuilder
    private func portConflictPanel(port: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 11)).foregroundStyle(.red)
                Text(holderHeadline(port: port))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            }
            HStack(spacing: 8) {
                Button {
                    isFreeing = true
                    Task {
                        _ = await app.freePortAndRetry(forwardID: forward.id)
                        isFreeing = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isFreeing {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "bolt.slash.fill").font(.system(size: 10, weight: .bold))
                        }
                        Text(isFreeing ? "Freeing…" : "Free port and retry")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        LinearGradient(colors: [Color.red.opacity(0.95), Color.red.opacity(0.75)],
                                       startPoint: .top, endPoint: .bottom),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(isFreeing)
                .help("Send SIGTERM (then SIGKILL) to whichever process holds port \(port), then retry")

                Button {
                    Task { await loadPortHolder() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Re-check who is holding the port")
                Spacer()
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.red.opacity(0.20), lineWidth: 0.5)
        )
        .task { await loadPortHolder() }
    }

    private func holderHeadline(port: Int) -> String {
        if let h = portHolder {
            let name = h.command ?? "process"
            return "Port \(port) is held by \(name) (PID \(h.pid))"
        }
        return "Port \(port) is in use"
    }

    @MainActor
    private func loadPortHolder() async {
        portHolder = await app.portHolder(forwardID: forward.id)
    }

    private func statusPill(_ text: String, icon: String, color: Color, base: Font, bg: AnyShapeStyle) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
            Text(text).font(base).foregroundStyle(.primary).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.20), lineWidth: 0.5))
        .padding(.leading, 11)
    }

    private func logsView(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("OUTPUT")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.suffix(80).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 140)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.black.opacity(0.25))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
    }
}

// MARK: - Add: search step

private struct AddSearchScreen: View {
    @Environment(AppState.self) private var app
    @Binding var screen: MenuBarView.Screen
    @State private var query: String = ""
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Add forward") {
                BackButton { screen = .list }
            } trailing: {
                HeaderIconButton(systemImage: "arrow.clockwise", help: "Refresh catalog") {
                    Task { await app.refreshCatalog(force: true) }
                }
            }
            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search services across all clusters", text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onChange(of: query) { _, new in
                        app.searchQuery = new
                        Task { await app.runSearch() }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        app.searchQuery = ""
                        Task { await app.runSearch() }
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            results

            Divider()
            ManualEntryCTA { screen = .addManual }
        }
        .onAppear {
            queryFocused = true
            app.searchQuery = query
            // Auto-retry: refresh if catalog is empty, stale (>30s), or has reachability errors.
            let needsRefresh: Bool = {
                if app.lastCatalogRefresh == nil { return true }
                if !app.contextRefreshErrors.isEmpty { return true }
                if let last = app.lastCatalogRefresh, Date().timeIntervalSince(last) > 30 { return true }
                return false
            }()
            if needsRefresh {
                Task { await app.refreshCatalog(force: true) }
            } else {
                Task { await app.runSearch() }
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if app.lastCatalogRefresh == nil {
            VStack(spacing: 8) {
                ProgressView()
                Text("Indexing services…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if app.searchResults.isEmpty {
            VStack(spacing: 8) {
                Text(query.isEmpty ? "Start typing to search." : "No matches for \"\(query)\".")
                    .foregroundStyle(.secondary).font(.caption)
                if !app.contextRefreshErrors.isEmpty {
                    Button {
                        Task { await app.refreshCatalog(force: true) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("\(app.contextRefreshErrors.count) cluster(s) unreachable — retry")
                        }
                        .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    let groups = groupResults(app.searchResults)
                    ForEach(groups, id: \.key) { group in
                        Section {
                            ForEach(group.services) { svc in
                                resultRow(svc)
                                Divider().opacity(0.3)
                            }
                        } header: {
                            Text(group.key)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14).padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.thinMaterial)
                        }
                    }
                }
            }
            .frame(maxHeight: 400)
        }
    }

    private func resultRow(_ svc: KubeService) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(svc.name).font(.body)
                Text(portsLabel(svc)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { screen = .addConfigure(svc) }
    }

    private func portsLabel(_ svc: KubeService) -> String {
        if svc.ports.isEmpty { return "no ports" }
        return svc.ports.map { p in
            if let n = p.name, !n.isEmpty { return "\(n):\(p.port)" }
            return ":\(p.port)"
        }.joined(separator: " · ")
    }

    private struct Group { let key: String; let services: [KubeService] }
    private func groupResults(_ services: [KubeService]) -> [Group] {
        var dict: [String: [KubeService]] = [:]
        for svc in services {
            dict["\(svc.context) / \(svc.namespace)", default: []].append(svc)
        }
        return dict.keys.sorted().map { Group(key: $0, services: dict[$0] ?? []) }
    }
}

// MARK: - Add: configure step

private struct AddConfigureScreen: View {
    @Environment(AppState.self) private var app
    let service: KubeService
    @Binding var screen: MenuBarView.Screen

    @State private var displayName: String = ""
    @State private var portIndex: Int = 0
    @State private var localPort: String = ""
    @State private var autoStart: Bool = false
    @State private var startNow: Bool = true
    @State private var validationError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Configure") {
                BackButton { screen = .addSearch }
            } trailing: {
                EmptyView()
            }
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name).font(.body.bold())
                    Text("\(service.context) / \(service.namespace)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                row("Name") { TextField("display name", text: $displayName) }
                row("Remote") {
                    if service.ports.isEmpty {
                        Text("No ports declared").foregroundStyle(.red).font(.caption)
                    } else {
                        Picker("", selection: $portIndex) {
                            ForEach(Array(service.ports.enumerated()), id: \.offset) { i, p in
                                Text(portLabel(p)).tag(i)
                            }
                        }
                        .labelsHidden()
                    }
                }
                row("Local") {
                    TextField("port", text: $localPort).frame(width: 90)
                }

                Toggle("Auto-start at launch", isOn: $autoStart)
                    .toggleStyle(.checkbox).controlSize(.small)
                Toggle("Start now", isOn: $startNow)
                    .toggleStyle(.checkbox).controlSize(.small)

                if let validationError {
                    Text(validationError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(14)

            Divider()
            HStack {
                Button("Cancel") { screen = .addSearch }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(service.ports.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onAppear {
            displayName = "\(service.name) (\(shortNamespace(service.namespace)))"
            if let firstPort = service.ports.first {
                localPort = String(suggestLocalPort(remote: firstPort.port))
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
            content()
        }
    }

    private func portLabel(_ p: KubeServicePort) -> String {
        if let n = p.name, !n.isEmpty { return "\(n) — \(p.port)" }
        return String(p.port)
    }

    private func shortNamespace(_ ns: String) -> String {
        if let dash = ns.firstIndex(of: "-"), ns[ns.startIndex..<dash].allSatisfy(\.isNumber) {
            return String(ns[ns.index(after: dash)...])
        }
        return ns
    }

    private func suggestLocalPort(remote: Int) -> Int {
        if remote == 3000 { return 3100 }
        if remote == 80 { return 8080 }
        if remote == 443 { return 8443 }
        return remote >= 1024 ? remote : 8000 + remote
    }

    private func save() {
        guard let lp = Int(localPort), lp >= 1024, lp <= 65535 else {
            validationError = "Local port must be 1024–65535"
            return
        }
        guard portIndex < service.ports.count else { return }
        let pf = PortForward(
            displayName: displayName.isEmpty ? service.name : displayName,
            context: service.context,
            namespace: service.namespace,
            serviceName: service.name,
            localPort: lp,
            remotePort: service.ports[portIndex].port,
            autoStart: autoStart
        )
        Task {
            await app.add(pf)
            if startNow { await app.start(forward: pf) }
            await MainActor.run { screen = .list }
        }
    }
}

// MARK: - Add: manual entry (no catalog needed)

private struct AddManualScreen: View {
    @Environment(AppState.self) private var app
    @Binding var screen: MenuBarView.Screen

    @State private var displayName: String = ""
    @State private var contextName: String = ""
    @State private var namespace: String = ""
    @State private var serviceName: String = ""
    @State private var localPort: String = "3100"
    @State private var remotePort: String = "3000"
    @State private var autoStart: Bool = false
    @State private var startNow: Bool = true
    @State private var validationError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Manual entry") {
                BackButton { screen = .addSearch }
            } trailing: {
                EmptyView()
            }
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Use this when cluster-wide service listing is not permitted.")
                    .font(.caption2).foregroundStyle(.secondary)

                row("Name") { TextField("display name", text: $displayName) }
                row("Cluster") {
                    Picker("", selection: $contextName) {
                        ForEach(app.contexts) { ctx in
                            Text(ctx.name).tag(ctx.name)
                        }
                        if app.contexts.isEmpty {
                            Text("(none)").tag("")
                        }
                    }
                    .labelsHidden()
                }
                row("Namespace") { TextField("e.g. 271-goldgard-staging", text: $namespace) }
                row("Service") { TextField("e.g. goldgard-api", text: $serviceName) }
                row("Local") {
                    TextField("port", text: $localPort).frame(width: 80)
                    Text("→").foregroundStyle(.secondary)
                    Text("Remote").font(.caption).foregroundStyle(.secondary)
                    TextField("port", text: $remotePort).frame(width: 80)
                }

                Toggle("Auto-start at launch", isOn: $autoStart)
                    .toggleStyle(.checkbox).controlSize(.small)
                Toggle("Start now", isOn: $startNow)
                    .toggleStyle(.checkbox).controlSize(.small)

                if let validationError {
                    Text(validationError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(14)

            Divider()
            HStack {
                Button("Cancel") { screen = .addSearch }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onAppear {
            if contextName.isEmpty {
                contextName = app.contexts.first(where: \.isCurrent)?.name
                    ?? app.contexts.first?.name ?? ""
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            content()
        }
    }

    private func save() {
        guard !contextName.isEmpty else { validationError = "Pick a cluster"; return }
        guard !namespace.isEmpty else { validationError = "Namespace is required"; return }
        guard !serviceName.isEmpty else { validationError = "Service name is required"; return }
        guard let lp = Int(localPort), lp >= 1024, lp <= 65535 else {
            validationError = "Local port must be 1024–65535"; return
        }
        guard let rp = Int(remotePort), rp >= 1, rp <= 65535 else {
            validationError = "Remote port must be 1–65535"; return
        }

        let pf = PortForward(
            displayName: displayName.isEmpty ? "\(serviceName) (\(namespace))" : displayName,
            context: contextName,
            namespace: namespace,
            serviceName: serviceName,
            localPort: lp,
            remotePort: rp,
            autoStart: autoStart
        )
        Task {
            await app.add(pf)
            if startNow { await app.start(forward: pf) }
            await MainActor.run { screen = .list }
        }
    }
}

// MARK: - Edit existing forward

private struct EditForwardScreen: View {
    @Environment(AppState.self) private var app
    let forwardID: UUID
    @Binding var screen: MenuBarView.Screen

    @State private var displayName: String = ""
    @State private var contextName: String = ""
    @State private var namespace: String = ""
    @State private var serviceName: String = ""
    @State private var localPort: String = ""
    @State private var remotePort: String = ""
    @State private var autoStart: Bool = false
    @State private var validationError: String?
    @State private var loaded: Bool = false

    private var current: PortForward? {
        app.forwards.first(where: { $0.id == forwardID })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Edit forward") {
                BackButton { screen = .list }
            } trailing: {
                EmptyView()
            }
            Divider()

            if let pf = current {
                VStack(alignment: .leading, spacing: 8) {
                    row("Name") { TextField("display name", text: $displayName) }
                    row("Cluster") {
                        Picker("", selection: $contextName) {
                            ForEach(app.contexts) { ctx in
                                Text(ctx.name).tag(ctx.name)
                            }
                            // Allow keeping the current value even if not in list anymore
                            if !app.contexts.contains(where: { $0.name == contextName }) && !contextName.isEmpty {
                                Text(contextName).tag(contextName)
                            }
                        }
                        .labelsHidden()
                    }
                    row("Namespace") { TextField("namespace", text: $namespace) }
                    row("Service") { TextField("service name", text: $serviceName) }
                    row("Local") {
                        TextField("port", text: $localPort).frame(width: 80)
                        Text("→").foregroundStyle(.secondary)
                        Text("Remote").font(.caption).foregroundStyle(.secondary)
                        TextField("port", text: $remotePort).frame(width: 80)
                    }

                    Toggle("Auto-start at launch", isOn: $autoStart)
                        .toggleStyle(.checkbox).controlSize(.small)

                    if app.states[pf.id]?.isActive == true {
                        Text("Saving will stop and restart this forward.")
                            .font(.caption2).foregroundStyle(.orange)
                    }

                    if let validationError {
                        Text(validationError).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(14)
            } else {
                Text("Forward not found.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 30)
                    .frame(maxWidth: .infinity)
            }

            Divider()
            HStack {
                Button("Cancel") { screen = .list }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(current == nil)
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onAppear {
            guard !loaded, let pf = current else { return }
            displayName = pf.displayName
            contextName = pf.context
            namespace = pf.namespace
            serviceName = pf.serviceName
            localPort = String(pf.localPort)
            remotePort = String(pf.remotePort)
            autoStart = pf.autoStart
            loaded = true
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            content()
        }
    }

    private func save() {
        guard let original = current else { return }
        guard !contextName.isEmpty else { validationError = "Pick a cluster"; return }
        guard !namespace.isEmpty else { validationError = "Namespace is required"; return }
        guard !serviceName.isEmpty else { validationError = "Service name is required"; return }
        guard let lp = Int(localPort), lp >= 1024, lp <= 65535 else {
            validationError = "Local port must be 1024–65535"; return
        }
        guard let rp = Int(remotePort), rp >= 1, rp <= 65535 else {
            validationError = "Remote port must be 1–65535"; return
        }

        var updated = original
        updated.displayName = displayName.isEmpty ? "\(serviceName) (\(namespace))" : displayName
        updated.context = contextName
        updated.namespace = namespace
        updated.serviceName = serviceName
        updated.localPort = lp
        updated.remotePort = rp
        updated.autoStart = autoStart

        let wasActive = app.states[original.id]?.isActive == true

        Task {
            if wasActive {
                await app.stop(id: original.id)
            }
            await app.update(updated)
            if wasActive {
                await app.start(forward: updated)
            }
            await MainActor.run { screen = .list }
        }
    }
}

// MARK: - Settings screen

private struct SettingsScreen: View {
    @Environment(AppState.self) private var app
    @Binding var screen: MenuBarView.Screen
    @State private var kubectlPath: String = ""
    @State private var extraPath: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Settings") {
                BackButton { screen = .list }
            } trailing: {
                EmptyView()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    clustersCard
                    binariesCard
                    importCard
                    aboutCard
                }
                .padding(12)
            }
            .frame(maxHeight: 460)
        }
        .onAppear {
            kubectlPath = app.kubectlPath
            extraPath = app.extraPath
        }
    }

    // MARK: cards

    private var clustersCard: some View {
        SettingsCard(
            icon: "server.rack",
            iconTint: .blue,
            title: "Clusters",
            subtitle: "\(app.contexts.count) configured · \(app.contextRefreshErrors.count) with errors"
        ) {
            VStack(spacing: 6) {
                if app.contexts.isEmpty {
                    Text("No contexts found in ~/.kube/config")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(app.contexts) { ctx in
                        ClusterRow(
                            ctx: ctx,
                            errorMessage: app.contextRefreshErrors[ctx.name].map(prettifyClusterError)
                        )
                    }
                }
                HStack {
                    Spacer()
                    PillButton(title: "Refresh", systemImage: "arrow.clockwise") {
                        Task {
                            await app.refreshContexts()
                            await app.refreshCatalog(force: true)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var binariesCard: some View {
        SettingsCard(
            icon: "terminal",
            iconTint: .purple,
            title: "Binaries",
            subtitle: "Where Tunnel finds kubectl and its plugins"
        ) {
            VStack(spacing: 8) {
                fieldRow(label: "kubectl", text: $kubectlPath, placeholder: "/usr/local/bin/kubectl") {
                    Task { await app.updateKubectlPath(kubectlPath) }
                }
                fieldRow(label: "PATH", text: $extraPath, placeholder: "/opt/homebrew/bin:…") {
                    Task { await app.updateExtraPath(extraPath) }
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text("PATH must include the directory holding the OIDC plugin (e.g. `~/.krew/bin` for kubelogin via krew).")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
    }

    private var importCard: some View {
        SettingsCard(
            icon: "tray.and.arrow.down",
            iconTint: .green,
            title: "Import",
            subtitle: "Re-scan ~/.zshrc for `pf-*` aliases"
        ) {
            HStack {
                PillButton(title: "Re-import from .zshrc", systemImage: "arrow.down.doc") {
                    Task {
                        let imports = app.loadZshrcImports()
                        await app.importAliases(imports)
                    }
                }
                Spacer()
                Text("Duplicates skipped").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private var aboutCard: some View {
        SettingsCard(
            icon: "point.3.connected.trianglepath.dotted",
            iconTint: .accentColor,
            title: "About",
            subtitle: nil
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tunnel 0.1.0").font(.system(size: 12, weight: .semibold))
                Text("kubectl port-forward manager")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func fieldRow(label: String, text: Binding<String>, placeholder: String, onApply: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 11, design: .monospaced))
            PillButton(title: "Apply", systemImage: nil, compact: true, action: onApply)
        }
    }

    /// Convert a raw KubectlError dump into a readable one-or-two-liner.
    private func prettifyClusterError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("forbidden") {
            return "Forbidden — no cluster-wide list permission. Use Manual entry to add forwards."
        }
        if lower.contains("unable to connect") || lower.contains("dial tcp") || lower.contains("no such host") {
            return "Cluster unreachable (network/VPN?)"
        }
        if lower.contains("code: 15") || lower.contains("timeout") || lower.contains("context deadline") {
            return "Timeout reaching API server"
        }
        if lower.contains("oidc-login") || lower.contains("authentication") {
            return "Authentication failed (re-run a forward to refresh token)"
        }
        // Fall back: extract a stderr-looking substring if present.
        if let range = raw.range(of: "stderr: \"") {
            let after = raw[range.upperBound...]
            let line = after.split(separator: "\n").first.map(String.init) ?? String(after)
            let trimmed = line.replacingOccurrences(of: "\\n", with: " ").prefix(140)
            return String(trimmed)
        }
        return String(raw.prefix(140))
    }
}

// MARK: - Settings sub-components

private struct SettingsCard<Content: View>: View {
    let icon: String
    let iconTint: Color
    let title: String
    let subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(iconTint.opacity(0.18))
                        .frame(width: 24, height: 24)
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(iconTint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private struct ClusterRow: View {
    let ctx: KubeContext
    let errorMessage: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(ctx.name)
                        .font(.system(size: 11.5, weight: ctx.isCurrent ? .semibold : .regular))
                    if ctx.isCurrent {
                        Text("active")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer(minLength: 0)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        if errorMessage != nil { return .red }
        return ctx.isCurrent ? .green : .secondary
    }
}

private struct PillButton: View {
    let title: String
    var systemImage: String? = nil
    var compact: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 4 : 5)
            .background(
                Capsule().fill(.primary.opacity(isHovered ? 0.14 : 0.08))
            )
            .overlay(
                Capsule().strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - First-run import screen

private struct ImportScreen: View {
    @Environment(AppState.self) private var app
    @Binding var screen: MenuBarView.Screen
    @State private var imports: [ImportedAlias] = []
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Import from .zshrc") {
                BackButton { screen = .list }
            } trailing: {
                EmptyView()
            }
            Divider()

            if imports.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("No `pf-*` aliases found in ~/.zshrc.").foregroundStyle(.secondary).font(.caption)
                }
                .padding(.vertical, 24).frame(maxWidth: .infinity)
            } else {
                Text("Found \(imports.count) candidate\(imports.count == 1 ? "" : "s") in ~/.zshrc.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.top, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(imports) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { selected.contains(item.id) },
                                    set: { v in
                                        if v { selected.insert(item.id) } else { selected.remove(item.id) }
                                    }
                                ))
                                .labelsHidden().toggleStyle(.checkbox)
                                .disabled(item.parsed == nil)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.aliasName).font(.callout.weight(.medium))
                                    if let pf = item.parsed {
                                        Text("\(pf.namespace) / \(pf.serviceName) — :\(pf.localPort) → \(pf.remotePort)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else if let note = item.note {
                                        Text(note).font(.caption).foregroundStyle(.red)
                                    }
                                }
                                Spacer(minLength: 4)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 4)
                            Divider().opacity(0.3)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            Divider()
            HStack {
                Button("Skip") {
                    Task {
                        await app.importAliases([])
                        screen = .list
                    }
                }
                Spacer()
                Button("Import selected") {
                    let chosen = imports.filter { selected.contains($0.id) }
                    Task {
                        await app.importAliases(chosen)
                        screen = .list
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onAppear {
            imports = app.loadZshrcImports()
            selected = Set(imports.filter { $0.parsed != nil }.map(\.id))
        }
    }
}

// MARK: - Status dot (shared)

struct StatusDot: View {
    let state: SessionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(.black.opacity(0.1)))
            .help(state.label)
    }

    private var color: Color {
        switch state {
        case .running: return .green
        case .connecting: return .yellow
        case .reconnecting: return .orange
        case .failed: return .red
        case .idle: return Color.secondary.opacity(0.5)
        }
    }
}
