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
// Test Engine: Runner and Context
//
// Two things live here.
//
// `TestContext` is the production object graph a workflow is handed — the
// real tunnels manager, the vault and its session, the extension gate, the
// split-tunnelling coordinator with its store and provider manager, the
// DNS proxy manager, both proxy daemon clients and the physical-interface
// resolver. A workflow fabricates a
// surface only where it says so; everything else is the shipping object.
//
// `PhantomTestEngine` is the runner: it drives the catalogue in order,
// emits the transcript as typed lines, and answers two ways of ending
// early — `stop()` cancels the task, `requestAbort(_:)` lets a workflow
// declare the environment unfit so the rest of the catalogue is not run
// against it.

#if DEBUG
import Foundation

enum OutputKind { case header, rule, step, info, ok, warn, error, skip, result }

struct OutputLine: Identifiable {
    let id = UUID()
    let text: String
    let kind: OutputKind
}

@MainActor
struct TestContext {
    let tunnels: TunnelsManager
    let vault: TunnelVaultClient
    let vaultSession: TunnelVaultSession
    let gate: ExtensionGateCoordinator
    let split: SplitTunnelingSessionCoordinator
    let splitStore: SplitTunnelingStore
    let splitManager: SplitTunnelProviderManager
    let dnsManager: DNSProxyProviderManager
    let dnsClient: DNSProxyDaemonClient
    let splitClient: SplitTunnelDaemonClient
    let interfaceResolver: PhysicalInterfaceResolver

    static let ghostName = "Test-Ghost"
    static let wireGuardName = "Test-WireGuard"

    func tunnel(named name: String) -> TunnelContainer? {
        tunnels.tunnels.first { $0.name == name }
    }
    var hasTestConfigs: Bool {
        tunnel(named: Self.ghostName) != nil && tunnel(named: Self.wireGuardName) != nil
    }
}

@Observable
@MainActor
final class PhantomTestEngine {

    static let shared = PhantomTestEngine()
    private init() {}

    private(set) var lines: [OutputLine] = []
    private(set) var isRunning = false

    @ObservationIgnored private var runTask: Task<Void, Never>?

    private(set) var abortReason: String?

    func requestAbort(_ reason: String) {
        guard !Task.isCancelled, abortReason == nil else { return }
        abortReason = reason
        emit("      suite abort requested: \(reason)", .error)
    }

    func reset() { lines = [] }
    func emit(_ text: String, _ kind: OutputKind) { lines.append(OutputLine(text: text, kind: kind)) }

    var plainText: String { lines.map(\.text).joined(separator: "\n") }

    func start(_ workflows: [TestWorkflow], _ ctx: TestContext) {
        guard !isRunning else { return }
        isRunning = true
        abortReason = nil
        reset()
        runTask = Task { [weak self] in
            await self?.run(workflows, ctx)
        }
    }

    func stop() { runTask?.cancel() }

    private func run(_ workflows: [TestWorkflow], _ ctx: TestContext) async {
        defer {
            isRunning = false
            runTask = nil
        }
        for (index, workflow) in workflows.enumerated() {
            if Task.isCancelled { break }
            if abortReason != nil { break }
            if index > 0 { emit("", .info) }
            emit("▸ \(workflow.displayName)", .header)
            emit(String(repeating: "─", count: 44), .rule)
            workflow._bind(ctx, self)
            await workflow._run()
        }
        emit("", .info)
        if Task.isCancelled {
            emit("— stopped —", .result)
        } else if let abortReason {
            emit("— aborted: \(abortReason) —", .result)
        } else {
            emit("— done —", .result)
        }
    }
}
#endif
