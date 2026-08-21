// ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
// ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
// ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
// ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
// ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
// ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
//
// Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
// Licensed under AGPL-3.0 - see LICENSE file for details
// WireGuard® is a registered trademark of Jason A. Donenfeld.
//
// Test Engine: Screen
//
// The DEBUG-only surface behind Settings → Test Engine. It assembles a
// `TestContext` from the environment — the same objects the app itself
// runs on — hands it to the runner, and renders the transcript with a
// colour and weight per `OutputKind`.
//
// A configuration gate stands in front of the runner: two tunnels named
// `Test-Ghost` and `Test-WireGuard` must be present, and the gate shows
// which of the two is missing rather than a single refusal. The
// activation paths drive those two rather than minting their own, so a
// run measures a tunnel that reached the vault the way the user's tunnels
// do; steps that need a disposable tunnel plant one and sweep it in
// teardown.
//
// The transcript can be copied or written to a timestamped file; a failed
// write reports itself rather than being swallowed.

#if DEBUG
import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
