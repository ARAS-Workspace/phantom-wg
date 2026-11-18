// Test Engine: Screen
//
// The DEBUG-only surface behind the ladybug button next to the language
// flag in the tunnel list. It assembles a `TestContext` from the
// environment — the same tunnels manager the app itself runs on — hands
// it to the runner, and renders the transcript with a colour and weight
// per `OutputKind`.
//
// The transcript can be copied or handed to the share sheet; every run
// also writes it to the file `PhantomTestEngine.transcriptURL` names.

#if DEBUG
import SwiftUI

struct TestEngineView: View {
    @Environment(TunnelsManager.self) private var tunnels
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    private let engine = PhantomTestEngine.shared

    private var s: TestEngineStrings { TestEngineStrings.of(loc.current) }

    private var ctx: TestContext {
        TestContext(tunnels: tunnels)
    }

    var body: some View {
        NavigationStack {
            runner
                .navigationTitle(s.navTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(s.close) { dismiss() }
                    }
                }
        }
        .onDisappear { engine.stop() }
    }

    // MARK: - Runner (control bar + flat log)

    private var runner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    engine.start(TestCatalog.workflows, ctx)
                } label: {
                    Label(s.run, systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.isRunning)

                if engine.isRunning {
                    Button {
                        engine.stop()
                    } label: {
                        Label(s.stop, systemImage: "stop.fill")
                    }
                    ProgressView()
                }
                Spacer()

                Button {
                    UIPasteboard.general.string = engine.plainText
                } label: {
                    Label(s.copy, systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .disabled(engine.lines.isEmpty)

                ShareLink(item: engine.plainText) {
                    Label(s.share, systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .disabled(engine.lines.isEmpty)
            }
            .padding(12)

            Divider()

            output
        }
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(engine.lines) { line in
                        // The transcript indents with spaces; on a phone a
                        // long line wraps, so the indent becomes padding and
                        // the wrapped part lines up under its own text.
                        let indent = line.text.prefix { $0 == " " }.count
                        let text = String(line.text.dropFirst(indent))
                        Text(text.isEmpty ? " " : text)
                            .font(font(line.kind))
                            .foregroundStyle(color(line.kind))
                            .textSelection(.enabled)
                            .padding(.leading, CGFloat(indent) * Self.indentWidth)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: engine.lines.count) { _, _ in
                if let last = engine.lines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .overlay {
                if engine.lines.isEmpty {
                    ContentUnavailableView(s.emptyTitle,
                                           systemImage: "text.append",
                                           description: Text(s.emptyDesc))
                }
            }
        }
    }

    // MARK: - Appearance

    /// One space of the caption-size monospaced face.
    private static let indentWidth: CGFloat = 7

    private func font(_ kind: OutputKind) -> Font {
        let base = Font.system(.caption, design: .monospaced)
        switch kind {
        case .header:  return base.weight(.bold)
        case .step:    return base.weight(.semibold)
        case .result:  return base.weight(.semibold)
        default:       return base
        }
    }

    private func color(_ kind: OutputKind) -> Color {
        switch kind {
        case .header:  return .primary
        case .rule:    return .secondary.opacity(0.5)
        case .step:    return .primary
        case .info:    return .secondary
        case .ok:      return .green
        case .warn:    return .orange
        case .error:   return .red
        case .skip:    return .orange
        case .result:  return .secondary
        }
    }
}
#endif
