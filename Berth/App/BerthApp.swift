import SwiftUI

@main
struct BerthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Berth is menu-bar-only; all UI lives inside the status item popover.
        // SwiftUI requires a Scene, so we provide an empty Settings scene and
        // strip the standard "Settings…" menu item to avoid an empty window.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) { }
            }
    }
}
