import SwiftUI

/// Draws a plain surface with the ghost mark over a screen while its
/// scene is not active — the app switcher, Control Center, or a system
/// prompt in front of the app. Applied at the app root, so it covers
/// every pushed screen, and inside the one sheet (the QR scanner),
/// which is presented above the root.
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
