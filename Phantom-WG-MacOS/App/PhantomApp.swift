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
// Phantom-WG for macOS — application entry point.
//
// ─── HOW TO READ THIS CODEBASE ────────────────────────────────────────
//
// Production sources carry no prose. Comments here do not explain, argue
// or restate what the code does — the code is the only authority on its
// own behaviour. What a comment may carry is a POINTER to where a claim
// is proven or where a decision is recorded.
//
// Three markers, plus the directives the linter itself reads:
//
//   /// @witness <Workflow>
//   /// @witness <Workflow>.<step>
//       The PhantomTestEngine harness drives this symbol and asserts on
//       it. `<Workflow>` names a workflow FAMILY under
//       `Phantom-WG-MacOS/PhantomTestEngine/workflows/` — one type,
//       sometimes continued across `+`-suffixed files — whose header says
//       what the family measures; some headers list the scenarios one by
//       one, others say why they do not. `<step>` names one method in that
//       family, which may live in any of its files. Grep the name to read
//       the actual assertions. A method carrying several workflow markers
//       is exercised from several angles.
//
//   /// @adr <NNNN>
//       The decision behind this shape is recorded in
//       `Documentation/ADR/English/<NNNN>-*.md`. The ADR carries the
//       reasoning, the alternatives and what was rejected. The code does
//       not repeat it.
//
//   // MARK: -
//       Navigation. It may name what a group of symbols is for, and a few
//       do carry a parenthetical about the group's shape — but a MARK is
//       never where a behavioural guarantee is recorded. That is a marker
//       or the ADR.
//
//   SwiftLint directives
//       Read by the linter, never by a reader. Carries no claim about
//       behaviour. (Not spelled out here: writing one would make this
//       legend a directive rather than a description of one.)
//
// The markers are NOT exhaustive. An unmarked symbol usually has no
// harness witness — but not always: the harness asserts on some symbols
// that carry no marker yet (`ConfParser.parse` and `TunnelResetReply.read`
// among them). So absence means "not annotated", never "not tested", and
// it never means the symbol is wrong or unimportant. Unwitnessed symbols
// are being collected deliberately rather than annotated, so the gap
// stays visible instead of being explained away.
//
// The test engine itself is documented differently: every file under
// `PhantomTestEngine/` opens with a header naming what it is and, where
// it drives something, what it drives; some also name what the file
// cannot prove. Read that header before reading its body — the bodies are
// bare on purpose.
//
// ──────────────────────────────────────────────────────────────────────

import SwiftUI

@main
@MainActor
struct PhantomApp: App {

    @State private var coordinator: ExtensionGateCoordinator
    @State private var sessionCoordinator: SplitTunnelingSessionCoordinator
    @State private var tunnelsManager: TunnelsManagerLoader
    @State private var loc: LocalizationManager
    @State private var splitTunnelingStore: SplitTunnelingStore
    @State private var splitProviderManager: SplitTunnelProviderManager
    @State private var dnsProviderManager: DNSProxyProviderManager
    @State private var dnsDaemonClient: DNSProxyDaemonClient
    @State private var splitDaemonClient: SplitTunnelDaemonClient
    @State private var interfaceResolver: PhysicalInterfaceResolver
    @State private var toastCenter: ToastCenter
    @State private var vaultClient: TunnelVaultClient
    @State private var vaultSession: TunnelVaultSession
    @State private var connectionGate: ConnectionGateCoordinator

    init() {
        let loc = LocalizationManager.shared
        let tunnelsManager = TunnelsManagerLoader()
        let splitTunnelingStore = SplitTunnelingStore()
        let splitProviderManager = SplitTunnelProviderManager()
        let dnsProviderManager = DNSProxyProviderManager()
        let dnsDaemonClient = DNSProxyDaemonClient()
        let splitDaemonClient = SplitTunnelDaemonClient()
        let vaultClient = TunnelVaultClient()
        let coordinator = ExtensionGateCoordinator(
            vault: vaultClient,
            splitDaemon: splitDaemonClient,
            dnsDaemon: dnsDaemonClient
        )
        let sessionCoordinator = SplitTunnelingSessionCoordinator(
            split: splitProviderManager,
            dns: dnsProviderManager,
            dnsDaemonClient: dnsDaemonClient,
            splitDaemonClient: splitDaemonClient
        )
        splitTunnelingStore.sessionCoordinator = sessionCoordinator

        _loc = State(initialValue: loc)
        _coordinator = State(initialValue: coordinator)
        _sessionCoordinator = State(initialValue: sessionCoordinator)
        _tunnelsManager = State(initialValue: tunnelsManager)
        _splitTunnelingStore = State(initialValue: splitTunnelingStore)
        _splitProviderManager = State(initialValue: splitProviderManager)
        _dnsProviderManager = State(initialValue: dnsProviderManager)
        _interfaceResolver = State(initialValue: PhysicalInterfaceResolver())
        _toastCenter = State(initialValue: ToastCenter())
        _vaultClient = State(initialValue: vaultClient)
        _vaultSession = State(initialValue: TunnelVaultSession(vault: vaultClient))
        _connectionGate = State(initialValue: ConnectionGateCoordinator(vault: vaultClient))
        _dnsDaemonClient = State(initialValue: dnsDaemonClient)
        _splitDaemonClient = State(initialValue: splitDaemonClient)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if coordinator.allReady {
                    if vaultSession.state == .ready {
                        if connectionGate.state == .slotFree {
                            TunnelContentView(loader: tunnelsManager)
                        } else {
                            ConnectionGateView()
                        }
                    } else {
                        TunnelVaultGateView()
                    }
                } else {
                    ExtensionGateView()
                }
            }
            .environment(loc)
            .environment(coordinator)
            .environment(sessionCoordinator)
            .environment(splitTunnelingStore)
            .environment(splitProviderManager)
            .environment(dnsProviderManager)
            .environment(dnsDaemonClient)
            .environment(splitDaemonClient)
            .environment(interfaceResolver)
            .environment(toastCenter)
            .environment(vaultClient)
            .environment(vaultSession)
            .environment(connectionGate)
            .tint(Color.accentColor)
            .frame(width: 560, height: 720)
            .onAppear {
                interfaceResolver.start()
                coordinator.start()
                connectionGate.currentTunnelsManager = { [tunnelsManager] in tunnelsManager.manager }
            }
            .onChange(of: coordinator.allReady) { _, ready in
                if !ready { vaultSession.invalidate() }
                if ready { tunnelsManager.manager?.releaseAbandonedStoreLatch() }
            }
            .task(id: vaultSession.state) {
                guard vaultSession.state == .ready else { return }
                connectionGate.start()
                connectionGate.checkAgain()
            }
            .task(id: coordinator.allReady) {
                guard coordinator.allReady else { return }
                let realign = await sessionCoordinator.boot { splitTunnelingStore.configuration }
                splitTunnelingStore.recordPush(realign)
            }
        }
        .windowResizability(.contentSize)
    }
}
