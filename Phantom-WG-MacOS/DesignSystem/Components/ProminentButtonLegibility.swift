import SwiftUI

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
    func prominentLabelLegibleWhenInactive() -> some View {
        modifier(ProminentLabelInactiveLegibility())
    }
}
