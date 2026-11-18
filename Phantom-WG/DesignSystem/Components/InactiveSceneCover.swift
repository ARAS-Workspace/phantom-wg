import SwiftUI

/// Draws a plain surface with the ghost mark over a screen while its
/// scene is not active — the app switcher, Control Center, or a system
/// prompt in front of the app. Applied to the two screens that show a
/// raw `.conf`, private key included: import and edit.
private struct InactiveSceneCover: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            if scenePhase != .active {
                ZStack {
                    Color(.systemGroupedBackground)
                    GhostGlyph()
                        .fill(.secondary, style: FillStyle(eoFill: true))
                        .frame(width: 64, height: 64)
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func coveredWhileInactive() -> some View {
        modifier(InactiveSceneCover())
    }
}
