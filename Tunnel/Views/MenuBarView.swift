import SwiftUI

/// Single-popover root view. Manages a screen stack internally so the entire
/// app lives inside the status item popover.
struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @State private var screen: Screen = .list
    @State private var expandedID: UUID?

    enum Screen: Equatable {
        case list
        case addType
        case addSSH
        case addSearch
        case addConfigure(KubeService)
        case addManual
        case editForward(UUID)
        case settings
    }

    var body: some View {
        VStack(spacing: 0) {
            switch screen {
            case .list:        ListScreen(screen: $screen, expandedID: $expandedID)
            case .addType:     AddTypeScreen(screen: $screen)
            case .addSSH:      SSHForwardScreen(original: nil, screen: $screen)
            case .addSearch:   AddSearchScreen(screen: $screen)
            case .addConfigure(let svc): AddConfigureScreen(service: svc, screen: $screen)
            case .addManual:   AddManualScreen(screen: $screen)
            case .editForward(let id):
                if let forward = app.forwards.first(where: { $0.id == id }), forward.ssh != nil {
                    SSHForwardScreen(original: forward, screen: $screen)
                } else {
                    EditForwardScreen(forwardID: id, screen: $screen)
                }
            case .settings:    SettingsScreen(screen: $screen)
            }
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// Shared by the popover and the template image in the macOS menu bar.
struct TunnelGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        path.move(to: point(0.06, 0.88))
        path.addLine(to: point(0.06, 0.51))
        path.addCurve(to: point(0.94, 0.51), control1: point(0.06, -0.06), control2: point(0.94, -0.06))
        path.addLine(to: point(0.94, 0.88))
        path.addLine(to: point(0.74, 0.88))
        path.addLine(to: point(0.74, 0.54))
        path.addCurve(to: point(0.26, 0.54), control1: point(0.74, 0.22), control2: point(0.26, 0.22))
        path.addLine(to: point(0.26, 0.88))
        path.closeSubpath()

        return path
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

private struct HomeIcon: View {
    var body: some View {
        TunnelGlyph()
            .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            .frame(width: 17, height: 17)
            .padding(.horizontal, 1)
            .accessibilityHidden(true)
    }
}

/// Standard leading content: a back chevron that runs the action.
private struct BackButton: View {
    let action: () -> Void
    var body: some View {
        HeaderIconButton(systemImage: "chevron.left", help: "Back", action: action)
    }
}

private struct HeaderIconButton: View {
    let systemImage: String
    let help: String
    var prominent = false
    var busy = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(prominent ? Color.white : Color.primary)
                }
            }
            .frame(width: 32, height: 32)
            .background(
                prominent ? Color.accentColor.opacity(isHovered ? 0.85 : 1) : Color.primary.opacity(isHovered ? 0.12 : 0.06),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .disabled(busy)
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
            Divider()
                .padding(.bottom, 8)
            if let err = app.configLoadError {
                configErrorBanner(err)
            }
            content
            footer
        }
        .padding(.horizontal, 17)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HomeIcon()
            Text("Tunnel")
                .font(.system(size: 19, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            if !app.forwards.isEmpty {
                statusSummary
            }
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                ListActionButton(icon: "plus", title: "Ajouter un tunnel", size: 17) {
                    screen = .addType
                }
                ListActionButton(icon: "gearshape", title: "Réglages") {
                    screen = .settings
                }
            }
        }
        .padding(.horizontal, 3)
        .padding(.top, 13)
        .padding(.bottom, 6)
        .contextMenu {
            Button("Réglages…", systemImage: "gearshape") {
                screen = .settings
            }
            Button("Recharger les tunnels", systemImage: "arrow.clockwise") {
                Task { await app.reloadFromDisk() }
            }
            .disabled(app.isReloadingConfig)
        }
    }

    private func configErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }

    private var statusSummary: some View {
        let s = app.currentSummary()
        let idle = app.forwards.filter { (app.states[$0.id] ?? .idle) == .idle }.count
        return HStack(spacing: 10) {
            if s.runningCount > 0 {
                statusDot(count: s.runningCount, label: "\(s.runningCount) \(s.runningCount == 1 ? "actif" : "actifs")", tint: .green)
            }
            if s.connectingCount > 0 || s.failedCount > 0 {
                let warnings = [
                    s.connectingCount > 0 ? "\(s.connectingCount) en cours" : nil,
                    s.failedCount > 0 ? "\(s.failedCount) \(s.failedCount == 1 ? "échec" : "échecs")" : nil,
                ].compactMap { $0 }
                statusDot(count: s.connectingCount + s.failedCount, label: warnings.joined(separator: " · "), tint: .orange)
            }
            if idle > 0 {
                statusDot(count: idle, label: "\(idle) \(idle == 1 ? "arrêté" : "arrêtés")", tint: .gray)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("État des tunnels")
    }

    private func statusDot(count: Int, label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(count, format: .number)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var content: some View {
        if app.forwards.isEmpty {
            EmptyStateView()
        } else {
            let kubernetes = app.forwards.filter { $0.ssh == nil }
            let ssh = app.forwards.filter { $0.ssh != nil }
            ScrollView {
                VStack(spacing: 8) {
                    if !kubernetes.isEmpty {
                        tunnelSection(kubernetes, isSSH: false)
                    }
                    if !kubernetes.isEmpty && !ssh.isEmpty {
                        Divider()
                    }
                    if !ssh.isEmpty {
                        tunnelSection(ssh, isSSH: true)
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 460)
        }
    }

    private func tunnelSection(_ forwards: [PortForward], isSSH: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                ProtocolIcon(isSSH: isSSH)
                Text(isSSH ? "SSH" : "Kubernetes")
                    .font(.system(size: 15, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 3)

            ForEach(forwards) { fw in
                ForwardRow(
                    forward: fw,
                    state: app.states[fw.id] ?? .idle,
                    isExpanded: expandedID == fw.id,
                    onToggleExpand: { expandedID = expandedID == fw.id ? nil : fw.id },
                    onEdit: { screen = .editForward(fw.id) }
                )
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Divider()
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Text("Quitter Tunnel")
                    Spacer()
                    Text("⌘Q")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .font(.system(size: 14))
                .padding(.horizontal, 3)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.bottom, 8)
    }
}

private struct ListActionButton: View {
    let icon: String
    let title: String
    var size: CGFloat = 14
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.primary.opacity(isHovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct ProtocolIcon: View {
    let isSSH: Bool

    var body: some View {
        ZStack {
            if isSSH {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .darkGray))
                HStack(alignment: .bottom, spacing: 2) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    RoundedRectangle(cornerRadius: 1)
                        .frame(width: 7, height: 1.5)
                }
                .foregroundStyle(.white)
            } else {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    func point(_ angle: Double, _ radius: Double) -> CGPoint {
                        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                    }

                    var badge = Path()
                    var spokes = Path()
                    for i in 0..<7 {
                        let angle = 2 * Double.pi * Double(i) / 7 - .pi / 2
                        let corner = point(angle, size.height / 2)
                        if i == 0 { badge.move(to: corner) } else { badge.addLine(to: corner) }
                        spokes.move(to: center)
                        spokes.addLine(to: point(angle, size.height * 0.36))
                    }
                    badge.closeSubpath()
                    context.fill(badge, with: .color(Color(red: 0.19, green: 0.42, blue: 0.90)))
                    let radius = size.height * 0.24
                    spokes.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                                  width: radius * 2, height: radius * 2))
                    context.stroke(spokes, with: .color(.white), style: StrokeStyle(lineWidth: 1.15, lineCap: .round))
                }
            }
        }
        .frame(width: 25, height: 25)
        .accessibilityHidden(true)
    }
}

// MARK: - Manual entry CTA (banner)

private struct ManualEntryCTA: View {
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
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
    var body: some View {
        VStack(spacing: 6) {
            HomeIcon().foregroundStyle(.secondary).padding(.bottom, 4)
            Text("Aucun tunnel").font(.headline)
            Text("Ajoutez un tunnel SSH ou Kubernetes avec le bouton +.")
                .font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Button(action: onToggleExpand) {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Text(forward.displayName).font(.system(size: 14))
                                .lineLimit(1)
                            Text(verbatim: ":\(forward.localPort)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        stateLabel
                    }
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(forward.displayName) · \(forward.portMapping) · \(forward.qualifiedTarget)")
                .accessibilityLabel("\(forward.displayName), port \(forward.localPort), \(statusAppearance.title)")
                .accessibilityHint(isExpanded ? "Masquer les détails" : "Afficher les détails")
                actionButton
            }
            .padding(.horizontal, 3)
            .onHover { isHovered = $0 }

            if isExpanded {
                ExpandedDetail(forward: forward, state: state, onEdit: onEdit)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .padding(.top, 2)
            }
        }
        .background(.primary.opacity(isHovered || isExpanded ? 0.06 : 0),
                    in: RoundedRectangle(cornerRadius: 7))
    }

    private var stateLabel: some View {
        let status = statusAppearance
        return HStack(spacing: 7) {
            Group {
                if state == .idle {
                    Circle()
                        .fill(.secondary.opacity(0.65))
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: status.icon)
                        .font(.system(size: 16, weight: .medium))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, status.tint)
                }
            }
            .frame(width: 17)
            Text(status.title)
                .font(.system(size: 12))
                .foregroundStyle(status.text)
                .lineLimit(1)
        }
        .frame(width: 124, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var statusAppearance: (title: String, icon: String, tint: Color, text: Color) {
        switch state {
        case .running:
            let green = Color(nsColor: .systemGreen)
            return ("Actif", "checkmark.circle.fill", green, Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? .systemGreen : NSColor(srgbRed: 0.02, green: 0.38, blue: 0.10, alpha: 1)
            }))
        case .connecting: return ("Connexion…", "ellipsis.circle.fill", .orange, .secondary)
        case .reconnecting: return ("Reconnexion…", "arrow.clockwise.circle.fill", .orange, .secondary)
        case .failed(.localPortInUse): return ("Port occupé", "exclamationmark.triangle.fill", .red, .red)
        case .failed: return ("Échec", "exclamationmark.triangle.fill", .red, .red)
        case .idle: return ("Arrêté", "circle.fill", .secondary, .secondary)
        }
    }

    private var actionButton: some View {
        let icon = state.isActive ? "stop.fill" : state.isFailed ? "arrow.clockwise" : "play.fill"
        let action = state.isActive ? "Arrêter" : state.isFailed ? "Réessayer" : "Démarrer"
        return ListActionButton(icon: icon, title: "\(action) : \(forward.displayName)") {
            Task {
                if state.isActive { await app.stop(id: forward.id) }
                else { await app.start(forward: forward) }
            }
        }
    }
}

private struct ExpandedDetail: View {
    @Environment(AppState.self) private var app
    let forward: PortForward
    let state: SessionState
    let onEdit: () -> Void

    @State private var portHolder: PortHolder?
    @State private var isFreeing: Bool = false
    @State private var showsLogs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.4)
            if case .failed(.localPortInUse(let port)) = state {
                portConflictPanel(port: port)
            } else {
                Text(forward.qualifiedTarget)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                statusLine
            }
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { forward.autoStart },
                    set: { v in Task { await app.setAutoStart(id: forward.id, v) } }
                )) {
                    Text("Démarrer à l’ouverture")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                Spacer()
                ListActionButton(icon: "pencil", title: "Modifier le tunnel", size: 12, action: onEdit)
                ListActionButton(icon: "trash", title: "Supprimer le tunnel", size: 12) {
                    Task { await app.delete(id: forward.id) }
                }
            }
            if let lines = app.liveLogs[forward.id], !lines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        showsLogs.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showsLogs ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .frame(width: 10)
                                .accessibilityHidden(true)
                            Text("Journal de connexion")
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showsLogs ? "Déplié" : "Replié")

                    if showsLogs {
                        logsView(lines)
                    }
                }
                .font(.caption)
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
            Label("\(binding) · since \(since.formatted(date: .omitted, time: .shortened))", systemImage: "link")
                .font(baseFont).foregroundStyle(.secondary)
                .textSelection(.enabled)
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
        HStack(spacing: 8) {
            Group {
                if let holder = portHolder {
                    Text("\(holder.command ?? "Processus inconnu") · PID \(String(holder.pid))")
                } else {
                    Text("Processus non identifié")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)

            Spacer(minLength: 0)

            Button {
                isFreeing = true
                Task {
                    _ = await app.freePortAndRetry(forwardID: forward.id)
                    isFreeing = false
                }
            } label: {
                Text(isFreeing ? "Libération…" : "Libérer et réessayer")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isFreeing)
            .help("Arrête le processus qui utilise le port \(port), puis relance le tunnel")
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Vérifier le port") { Task { await loadPortHolder() } }
                .disabled(isFreeing)
            Button("Ignorer l’erreur") { Task { await app.acknowledgeFailure(id: forward.id) } }
                .disabled(isFreeing)
        }
        .task(id: port) {
            portHolder = nil
            await loadPortHolder()
        }
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
    }

    private func logsView(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
                        .fill(.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
    }
}

// MARK: - Add: tunnel type and SSH form

private struct AddTypeScreen: View {
    @Binding var screen: MenuBarView.Screen

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Add tunnel") {
                BackButton { screen = .list }
            } trailing: { EmptyView() }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                option("SSH", subtitle: "Forward a port through an SSH host or alias", icon: "terminal") {
                    screen = .addSSH
                }
                option("Kubernetes", subtitle: "Find a service in your clusters", icon: "cube") {
                    screen = .addSearch
                }
            }
            .padding(12)
        }
    }

    private func option(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }
}

private struct SSHForwardScreen: View {
    @Environment(AppState.self) private var app
    let original: PortForward?
    @Binding var screen: MenuBarView.Screen
    @State private var name: String
    @State private var host: String
    @State private var remoteHost: String
    @State private var localPort: String
    @State private var remotePort: String
    @State private var autoStart: Bool
    @State private var startNow = true
    @State private var saving = false
    @State private var error: String?

    init(original: PortForward?, screen: Binding<MenuBarView.Screen>) {
        self.original = original
        _screen = screen
        _name = State(initialValue: original?.displayName ?? "")
        _host = State(initialValue: original?.ssh?.host ?? "")
        _remoteHost = State(initialValue: original?.ssh?.remoteHost ?? "127.0.0.1")
        _localPort = State(initialValue: original.map { String($0.localPort) } ?? "")
        _remotePort = State(initialValue: original.map { String($0.remotePort) } ?? "")
        _autoStart = State(initialValue: original?.autoStart ?? false)
    }

    private var back: MenuBarView.Screen { original == nil ? .addType : .list }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: original == nil ? "New SSH tunnel" : "Edit SSH tunnel") {
                BackButton { screen = back }
            } trailing: { EmptyView() }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                field("SSH host", placeholder: "e.g. vps", value: $host)
                Text("Uses your OpenSSH config (~/.ssh/config). A shell alias won't work here.")
                    .font(.caption).foregroundStyle(.secondary)
                field("Name (optional)", placeholder: "Defaults to SSH host", value: $name)
                field("Destination host", placeholder: "127.0.0.1", value: $remoteHost)
                HStack(alignment: .bottom, spacing: 10) {
                    field("Local port", placeholder: "8787", value: $localPort)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        .padding(.bottom, 4).accessibilityHidden(true)
                    field("Destination port", placeholder: "8787", value: $remotePort)
                }
                Text("Listens only on 127.0.0.1. The destination is reached from the SSH host.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    Toggle("Auto-start at launch", isOn: $autoStart)
                    if original == nil { Toggle("Start now", isOn: $startNow) }
                }
                .toggleStyle(.checkbox).controlSize(.small)
                if let original, app.states[original.id]?.isActive == true {
                    Text("Saving will restart this tunnel.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .padding(14)
            Divider()
            HStack {
                Button("Cancel") { screen = back }
                Spacer()
                Button(original == nil && startNow ? "Save & Start" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .disabled(saving)
    }

    private func field(_ label: String, placeholder: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium))
            TextField(label, text: value, prompt: Text(placeholder))
                .labelsHidden().textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = SSHForwardTarget(host: cleanHost, remoteHost: remoteHost.trimmingCharacters(in: .whitespacesAndNewlines))
        guard target.isValid else { error = "Enter an SSH alias or hostname and a destination hostname or IPv4 address."; return }
        guard let local = Int(localPort), (1024...65535).contains(local) else {
            error = "Local port must be 1024–65535."; return
        }
        guard let remote = Int(remotePort), (1...65535).contains(remote) else {
            error = "Destination port must be 1–65535."; return
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var forward = original ?? PortForward(displayName: cleanHost, ssh: target, localPort: local, remotePort: remote)
        forward.displayName = cleanName.isEmpty ? cleanHost : cleanName
        forward.ssh = target
        forward.localPort = local
        forward.remotePort = remote
        forward.autoStart = autoStart
        saving = true
        Task {
            if let original {
                let active = app.states[original.id]?.isActive == true
                await app.update(forward)
                if active { await app.start(forward: forward) }
            } else {
                await app.add(forward)
                if startNow { await app.start(forward: forward) }
            }
            screen = .list
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
            ScreenHeader(title: "Kubernetes services") {
                BackButton { screen = .addType }
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
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.namespace).font(.caption.weight(.semibold))
                                Text(group.context).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                                .padding(.horizontal, 14).padding(.vertical, 6)
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
        Button {
            screen = .addConfigure(svc)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(svc.name).font(.body)
                    Text(portsLabel(svc)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func portsLabel(_ svc: KubeService) -> String {
        if svc.ports.isEmpty { return "no ports" }
        return svc.ports.map { p in
            if let n = p.name, !n.isEmpty { return "\(n):\(p.port)" }
            return ":\(p.port)"
        }.joined(separator: " · ")
    }

    private struct Group {
        let key: String
        let services: [KubeService]
        var context: String { services.first?.context ?? "" }
        var namespace: String { services.first?.namespace ?? "" }
    }
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
            contextName = pf.context ?? ""
            namespace = pf.namespace ?? ""
            serviceName = pf.serviceName ?? ""
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
            ScreenHeader(title: "Réglages") {
                BackButton { screen = .list }
            } trailing: {
                EmptyView()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    clustersCard
                    binariesCard
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
                            errorMessage: app.contextRefreshErrors[ctx.name].map(prettifyClusterError),
                            errorDetails: app.contextRefreshErrors[ctx.name]
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

    private var aboutCard: some View {
        SettingsCard(
            icon: "arrow.left.arrow.right.circle",
            iconTint: .accentColor,
            title: "About",
            subtitle: nil
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tunnel \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.system(size: 12, weight: .semibold))
                Text("SSH and Kubernetes port forwards")
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
        if lower.contains("decodingfailed") {
            return "Couldn’t read the service list returned by kubectl."
        }
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
        return "Couldn’t load Kubernetes services."
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
    let errorDetails: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: errorMessage == nil ? "server.rack" : "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(errorMessage == nil ? Color.secondary : .orange)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(ctx.name)
                        .font(.system(size: 11.5, weight: ctx.isCurrent ? .semibold : .regular))
                    if ctx.isCurrent {
                        Text("Current").font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                if let errorMessage, let errorDetails {
                    DisclosureGroup {
                        Text(errorDetails)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    } label: {
                        Text(errorMessage).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
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
