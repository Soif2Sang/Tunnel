import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        Task { await appState.bootstrap() }
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted",
                                   accessibilityDescription: "Berth")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
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

        Task { @MainActor in
            for await summary in appState.summaryUpdates {
                self.applySummary(summary)
            }
        }
    }

    private func applySummary(_ summary: AppState.StatusSummary) {
        guard let button = statusItem?.button else { return }
        button.title = summary.runningCount > 0 ? " \(summary.runningCount)" : ""

        let symbolName = "point.3.connected.trianglepath.dotted"

        switch summary.tone {
        case .grey:
            // Idle: template rendering, system tints it to match dark/light menu bar.
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Berth")
            image?.isTemplate = true
            button.image = image
            button.contentTintColor = nil
        case .green, .yellow, .red:
            // Active states: render the symbol with palette config so EVERY layer
            // (dots + connecting lines) takes the chosen color, not just the primary layer.
            let color: NSColor = {
                switch summary.tone {
                case .green: return .systemGreen
                case .yellow: return .systemOrange
                case .red: return .systemRed
                default: return .controlAccentColor
                }
            }()
            let config = NSImage.SymbolConfiguration(paletteColors: [color])
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Berth")?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
            button.image = image
            button.contentTintColor = nil
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover = popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Take focus away from whatever app is below us, so its mouse-tracking
            // (hover effects, etc) stops firing while the user interacts with Berth.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
