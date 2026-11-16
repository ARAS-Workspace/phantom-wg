import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(loc.t("menubar_open")) {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: SceneID.mainWindow)
            NSApp.activate()
        }
    }
}
