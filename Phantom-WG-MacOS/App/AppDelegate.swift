import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtimeHost = AppRuntimeHost()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        runtimeHost.windowClosed()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            NSApp.setActivationPolicy(.accessory)
        }
        return false
    }
}
