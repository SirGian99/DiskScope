import SwiftUI

@main
struct DiskScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = ScanCoordinator()

    init() {
        // Developer hook: `DiskScope --selftest <path>` runs a correctness check
        // and exits before any UI is created.
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        }
        if CommandLine.arguments.contains("--benchmark") {
            Benchmark.run()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}

/// Ensures the app behaves as a regular foreground GUI app even when launched
/// from a hand-assembled bundle (no Xcode project involved).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
