import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            NSApp.setActivationPolicy(.accessory)
        }
        return false
    }
}
