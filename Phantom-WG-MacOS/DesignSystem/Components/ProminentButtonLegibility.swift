import SwiftUI

/// macOS drops a `.borderedProminent` button's accent fill while its
/// window is not key, but keeps the label white — in light mode that
/// is white-on-white, so the button visually vanishes while still
/// holding its layout slot. The gates make this the rule rather than
/// the exception: their primary action hands the user to System
/// Settings, so the window has just lost key status at the exact
/// moment the user looks back at it. Mirror AppKit's own non-key
/// default-button look instead: keep the system-chosen fill and move
/// the label to the primary label color while the window is out of
/// focus.
private struct ProminentLabelInactiveLegibility: ViewModifier {
    @Environment(\.controlActiveState) private var activeState

    @ViewBuilder
    func body(content: Content) -> some View {
        if activeState == .inactive {
            content.foregroundStyle(.primary)
        } else {
            content
        }
    }
}

extension View {
    /// Keeps a `.borderedProminent` label readable in a non-key window;
    /// apply right after `.buttonStyle(.borderedProminent)`.
    func prominentLabelLegibleWhenInactive() -> some View {
        modifier(ProminentLabelInactiveLegibility())
    }
}
