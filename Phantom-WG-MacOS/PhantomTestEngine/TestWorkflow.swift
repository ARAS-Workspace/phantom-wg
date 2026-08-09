#if DEBUG
import Foundation

/// One step: an English title and a pure async body. The body uses the
/// workflow's inherited helpers; nothing is threaded in.
struct WorkflowStep {
    let title: String
    let body: @MainActor () async -> Void
    init(_ title: String, _ body: @escaping @MainActor () async -> Void) {
        self.title = title
        self.body = body
    }
}

/// Base for a test workflow — the "test class" you subclass under
/// `PhantomTestEngine/workflows/` and register in `TestCatalog` (one line,
/// plug and play). Override `displayName` and `steps`; write each step
/// body as PURE test logic in English using the helpers below. The runner
/// injects the live context, so a step can reach anything the user can —
/// no per-workflow setup and no shared override needed.
@MainActor
class TestWorkflow {
    private var context: TestContext!
    private weak var engine: PhantomTestEngine?
    private var stepFailed = false

    // MARK: - Subclass surface (override these)

    /// The run title (English).
    var displayName: String { "" }
    /// True when the workflow needs a reachable endpoint. Declared for the
    /// catalog; server-free workflows run unconditionally.
    var needsServer: Bool { false }
    /// The ordered steps: an English title + a step method each.
    var steps: [WorkflowStep] { [] }

    // MARK: - Everything the app exposes to the user (no plumbing)

    var tunnels: TunnelsManager { context.tunnels }
    var vault: TunnelVaultClient { context.vault }
    var vaultSession: TunnelVaultSession { context.vaultSession }
    var gate: ExtensionGateCoordinator { context.gate }
    var split: SplitTunnelingSessionCoordinator { context.split }
    var splitStore: SplitTunnelingStore { context.splitStore }
    var splitManager: SplitTunnelProviderManager { context.splitManager }
    var dnsManager: DNSProxyProviderManager { context.dnsManager }
    var dnsClient: DNSProxyDaemonClient { context.dnsClient }
    var splitClient: SplitTunnelDaemonClient { context.splitClient }
    var interfaceResolver: PhysicalInterfaceResolver { context.interfaceResolver }
    func tunnel(named name: String) -> TunnelContainer? { context.tunnel(named: name) }

    // MARK: - Step helpers (English, indented under the current step)

    func log(_ text: String, _ level: OutputKind = .info) {
        engine?.emit("      \(text)", level)
    }
    func fail(_ message: String? = nil) {
        stepFailed = true
        if let message { log(message, .error) }
    }
    /// Logs the outcome (ok/error) and fails the step when false.
    @discardableResult
    func check(_ condition: Bool, _ message: String) -> Bool {
        log(message, condition ? .ok : .error)
        if !condition { stepFailed = true }
        return condition
    }

    // MARK: - Runner entry (not for subclasses)

    func _bind(_ context: TestContext, _ engine: PhantomTestEngine) {
        self.context = context
        self.engine = engine
    }
    func _run() async {
        for step in steps {
            stepFailed = false
            engine?.emit("  • \(step.title)", .step)
            await step.body()
            engine?.emit(stepFailed ? "    ✗ FAIL" : "    ✓ PASS",
                         stepFailed ? .error : .ok)
        }
    }
}
#endif
