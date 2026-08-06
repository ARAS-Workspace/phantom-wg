import SwiftUI

extension View {

    /// Preview-grade mirror of `PhantomApp`'s composition root: builds
    /// the same object graph with `PreviewFixtures` instances and
    /// injects the full environment stack in one call, so every
    /// `#Preview` reads like `SomeView().previewEnvironment()`.
    ///
    /// One deliberate difference from production: `TunnelsManager` is
    /// injected here as well. The app injects it only after
    /// `TunnelsManagerLoader` finishes its async load; previews start
    /// with it ready.
    @MainActor
    func previewEnvironment(
        tunnels: TunnelsManager? = nil,
        scheme: ColorScheme? = nil
    ) -> some View {
        self
            .environment(LocalizationManager.shared)
            .environment(tunnels ?? PreviewFixtures.tunnelsManager())
            .tint(Color.accentColor)
            // `nil` follows the system appearance — pass a scheme only
            // in the paired Light/Dark preview variants.
            .preferredColorScheme(scheme)
    }
}

/// Generic `@State` host so previews can hand a real, interactive
/// `Binding` to views that require one — no per-preview host structs.
struct PreviewBindingHost<Value, Content: View>: View {

    @State private var value: Value
    private let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initial)
        self.content = content
    }

    var body: some View {
        content($value)
    }
}
