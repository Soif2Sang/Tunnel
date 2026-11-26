import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?
    private var statusBadge: StatusBadgeView?
    private var popover: NSPopover?
    private var globalClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        installGlobalClickMonitor()
        Task { await appState.bootstrap() }
    }

    /// Close our popover whenever the user mouses-down anywhere outside our app.
    /// Required because NSPopover.behavior = .transient does NOT reliably dismiss
    /// when the user clicks another menu-bar status item.
    private func installGlobalClickMonitor() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, let popover = self.popover, popover.isShown else { return }
                popover.performClose(nil)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Run async cleanup first, then green-light termination.
        Task { @MainActor in
            await appState.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Last-resort safety net: if shouldTerminate didn't run, still try to send SIGTERM.
        Task { await appState.shutdown() }
    }

    private func setupStatusItem() {
        // The popover is anchored to this button. Neither its width nor its
        // content layout should change as tunnels start and stop.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.image = makeStatusIcon()
            button.target = self
            button.action = #selector(togglePopover(_:))

            // Keep the glyph a template image so AppKit can adapt it independently of the badge.
            let badge = StatusBadgeView()
            badge.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
                badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
                badge.widthAnchor.constraint(equalToConstant: 7),
                badge.heightAnchor.constraint(equalTo: badge.widthAnchor),
            ])
            statusBadge = badge
        }

        let popover = NSPopover()
        popover.behavior = .transient
        // Disable AppKit's own resize animation — SwiftUI handles content transitions.
        // Without this, the popover's resize fights with our spring animations and causes layout jumps.
        popover.animates = false
        let host = NSHostingController(
            rootView: MenuBarView()
                .environment(appState)
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        self.statusItem = item
        self.popover = popover
        applySummary(appState.currentSummary())

        Task { @MainActor in
            for await summary in appState.summaryUpdates {
                self.applySummary(summary)
            }
        }
    }

    private func applySummary(_ summary: AppState.StatusSummary) {
        guard let button = statusItem?.button else { return }
        let description = "Tunnel — Active: \(summary.runningCount), connecting: \(summary.connectingCount), failed: \(summary.failedCount)"
        button.toolTip = description
        button.setAccessibilityLabel(description)
        let tint: NSColor?
        switch summary.status {
        case .idle: tint = nil
        case .running: tint = .systemGreen
        case .connecting: tint = .systemOrange
        case .failed: tint = .systemRed
        }
        statusBadge?.tint = tint
    }

    private func makeStatusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: true) { rect in
            let glyph = TunnelGlyph().path(in: rect.insetBy(dx: 1, dy: 1))
            let stroke = glyph.strokedPath(StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round))
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(stroke.cgPath)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover = popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Take focus away from whatever app is below us, so its mouse-tracking
            // (hover effects, etc) stops firing while the user interacts with Tunnel.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

private final class StatusBadgeView: NSView {
    var tint: NSColor? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tint else { return }
        tint.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    // Clicking the badge should still open the popover through the status button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
