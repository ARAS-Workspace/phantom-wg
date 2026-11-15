import SwiftUI
import AppKit

struct WindowSizeCommands: Commands {

    let loc: LocalizationManager

    var body: some Commands {
        CommandGroup(after: .windowSize) {
            Button(loc.t("window_default_size")) {
                Self.applyDefaultFrame(to: NSApp.mainWindow)
            }
        }
    }

    @MainActor
    static func applyDefaultFrame(to window: NSWindow?) {
        guard let window,
              !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(WindowSizing.defaultFrame(in: screen.visibleFrame), display: true, animate: true)
    }
}
