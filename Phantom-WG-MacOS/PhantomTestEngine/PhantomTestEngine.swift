#if DEBUG
import Foundation

// Core: the flat output model, the live context (everything the app
// exposes to the user), and the runner. The workflow base class lives in
// TestWorkflow.swift, the workflows under workflows/, their one-line
// registration in TestCatalog. DEBUG-only two ways: this guard and
// project.yml's EXCLUDED_SOURCE_FILE_NAMES.

/// A single output line's kind, for colour and nothing else. The output
/// is a flat, readable text stream (like the tunnel/split log panels),
/// not a widget tree.
enum OutputKind { case header, rule, step, info, ok, warn, error, result }

struct OutputLine: Identifiable {
    let id = UUID()
    let text: String
    let kind: OutputKind
}

/// The exact singletons PhantomApp injected, obtained by the panel via
/// @Environment (not re-instantiated). Handed to every workflow so a step
/// can drive anything the user can — no per-workflow setup, no override.
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

    /// The door's fuel: two configs the user must supply.
    static let ghostName = "Test-Ghost"
    static let wireGuardName = "Test-WireGuard"

    func tunnel(named name: String) -> TunnelContainer? {
        tunnels.tunnels.first { $0.name == name }
    }
    var hasTestConfigs: Bool {
        tunnel(named: Self.ghostName) != nil && tunnel(named: Self.wireGuardName) != nil
    }
}

/// The runner. Runs the catalog's workflows IN ORDER against the live
/// context and appends a flat, readable, saveable text stream.
@Observable
@MainActor
final class PhantomTestEngine {
    private(set) var lines: [OutputLine] = []
    private(set) var isRunning = false

    func reset() { lines = [] }
    func emit(_ text: String, _ kind: OutputKind) { lines.append(OutputLine(text: text, kind: kind)) }

    /// The full output as plain text — copyable and saveable.
    var plainText: String { lines.map(\.text).joined(separator: "\n") }

    func run(_ workflows: [TestWorkflow], _ ctx: TestContext) async {
        reset()
        isRunning = true
        defer { isRunning = false }
        for (index, workflow) in workflows.enumerated() {
            if index > 0 { emit("", .info) }
            emit("▸ \(workflow.displayName)", .header)
            emit(String(repeating: "─", count: 44), .rule)
            workflow._bind(ctx, self)
            await workflow._run()
        }
        emit("", .info)
        emit("— done —", .result)
    }
}
#endif
