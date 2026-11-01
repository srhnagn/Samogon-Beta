import AppKit

@MainActor
public final class AeroAppDelegate: NSObject, NSApplicationDelegate {
    public let appState = AppState()
    public private(set) var multiDisplayCoordinator: NotchMultiDisplayCoordinator?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an ultra-lightweight accessory utility (no Dock icon, zero window chrome)
        NSApp.setActivationPolicy(.accessory)

        self.multiDisplayCoordinator = NotchMultiDisplayCoordinator(appState: appState)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
public enum AeroApp {
    public static func main() {
        let app = NSApplication.shared
        let delegate = AeroAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
