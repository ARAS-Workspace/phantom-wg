#if DEBUG
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// DEBUG-only in-app test surface, reached from the gear menu beside
/// Uninstall. Mounted inside the TunnelListView subtree, so it reads
/// every live service the app exposes via @Environment. Play runs the
/// catalog's workflows in order; the output is one flat, readable,
/// saveable text stream. UI follows the user's language; workflow output
/// is English. Never in Release.
struct TestEngineView: View {
    @Environment(TunnelsManager.self) private var tunnels
    @Environment(TunnelVaultClient.self) private var vault
    @Environment(TunnelVaultSession.self) private var vaultSession
    @Environment(ExtensionGateCoordinator.self) private var gate
    @Environment(SplitTunnelingSessionCoordinator.self) private var split
    @Environment(SplitTunnelingStore.self) private var splitStore
    @Environment(SplitTunnelProviderManager.self) private var splitManager
    @Environment(DNSProxyProviderManager.self) private var dnsManager
    @Environment(DNSProxyDaemonClient.self) private var dnsClient
    @Environment(SplitTunnelDaemonClient.self) private var splitClient
    @Environment(PhysicalInterfaceResolver.self) private var interfaceResolver
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    /// Not `@State`: the runner outlives this sheet on purpose, so the
    /// single-run latch and the Stop handle survive a close/reopen.
    private let engine = PhantomTestEngine.shared
    @State private var savingError: String?
    @State private var showingSaveError = false

    private var s: TestEngineStrings { TestEngineStrings.of(loc.current) }

    private var ctx: TestContext {
        TestContext(tunnels: tunnels, vault: vault, vaultSession: vaultSession,
                    gate: gate, split: split, splitStore: splitStore,
                    splitManager: splitManager, dnsManager: dnsManager,
                    dnsClient: dnsClient, splitClient: splitClient,
                    interfaceResolver: interfaceResolver)
    }

    var body: some View {
        NavigationStack {
            Group {
                // `engine.isRunning` keeps an in-flight run's controls
                // and stream even if the named configs blink out of
                // the live list mid-run (a reconcile rebuild) — the
                // gate returns once the run ends.
                if ctx.hasTestConfigs || engine.isRunning {
                    runner
                } else {
                    configGate
                }
            }
            .navigationTitle(s.navTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(s.close) { dismiss() }
                }
            }
            .alert(s.saveErrorTitle, isPresented: $showingSaveError) {
                Button(s.ok) {}
            } message: {
                Text(savingError ?? "")
            }
        }
        .frame(minWidth: 560, minHeight: 600)
        // A dismissed sheet must not keep driving live tunnels: the run
        // is cancelled with the view, the runner reports "stopped", and
        // each workflow's teardown net sweeps what its steps planted.
        // Exactly the Stop button's path — same call, same latch, same
        // teardown — because the runner is process-wide. Reopening the
        // sheet while that teardown is still finishing finds Run
        // disabled rather than a second run over the same services.
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
                .prominentLabelLegibleWhenInactive()
                .disabled(engine.isRunning)

                if engine.isRunning {
                    Button {
                        engine.stop()
                    } label: {
                        Label(s.stop, systemImage: "stop.fill")
                    }
                    ProgressView().controlSize(.small)
                }
                Spacer()

                Button { copyOutput() } label: {
                    Label(s.copy, systemImage: "doc.on.doc")
                }
                .disabled(engine.lines.isEmpty)

                Button { saveOutput() } label: {
                    Label(s.save, systemImage: "square.and.arrow.down")
                }
                .disabled(engine.lines.isEmpty)
            }
            .padding(10)

            Divider()

            output
        }
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(engine.lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(font(line.kind))
                            .foregroundStyle(color(line.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: engine.lines.count) { _, _ in
                if let last = engine.lines.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
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

    // MARK: - Config gate (tight, live per-config status)

    private var configGate: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
            Text(s.gateTitle).font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                Text(s.gateIntro).font(.callout).foregroundStyle(.secondary)
                configRow(TestContext.ghostName, "Ghost",
                          present: ctx.tunnel(named: TestContext.ghostName) != nil)
                configRow(TestContext.wireGuardName, "WireGuard",
                          present: ctx.tunnel(named: TestContext.wireGuardName) != nil)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(s.gateReturn).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 400)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func configRow(_ name: String, _ type: String, present: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: present ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(present ? .green : .secondary)
            Text(name).font(.system(.callout, design: .monospaced))
            Text("(\(type))").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Save / copy

    private func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(engine.plainText, forType: .string)
    }

    private func saveOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "phantom-testengine-\(timestamp()).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (engine.plainText + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            savingError = error.localizedDescription
            showingSaveError = true
        }
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        // Fixed-format output must not drift with the user's calendar
        // or numbering system.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - Appearance

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
