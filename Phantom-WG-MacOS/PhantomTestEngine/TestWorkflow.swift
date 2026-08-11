#if DEBUG
import Foundation

/// Reply from the tunnel extension's app-message surface. The two
/// negative shapes are different claims and must not be told the same
/// way: `.empty` is the extension answering "no" (its documented
/// contract for empty and unknown messages), `.unanswered` is nobody
/// answering at all — the session refused the send or the reply never
/// came within the timeout.
enum ProviderReply: Equatable {
    case data(Data)
    case empty
    case unanswered

    var label: String {
        switch self {
        case .data(let d): return "data(\(d.count) bytes)"
        case .empty: return "empty"
        case .unanswered: return "unanswered"
        }
    }
}

// The one-shot continuation guard the helpers ride is the production
// `SingleResume` (Infrastructure/Concurrency/SingleResume.swift) —
// the DEBUG-local mirror this file used to carry is retired.

/// One step: an English title and a pure async body. The body uses the
/// workflow's inherited helpers; nothing is threaded in. A body does
/// its work inline (await) — never in a spawned Task — so log lines
/// and the PASS/FAIL verdict attribute to the right step.
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
    private var stepSkipReason: String?

    // MARK: - Subclass surface (override these)

    /// The run title (English).
    var displayName: String { "" }
    /// The ordered steps: an English title + a step method each. A
    /// server-dependent claim does not need declaring up front: the
    /// step that owns it reports `skip("environment: …")` when the
    /// answer never comes.
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

    /// Raw XPC vault path for injection steps — writes bytes the app's
    /// encoder would never produce. Fresh per workflow.
    let vaultRaw = TestVaultRawClient()

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
    /// Marks the step as skipped: for claims whose precondition is not
    /// met — usually the environment (a server that did not answer).
    /// A skip is honest reporting, not a failure; `fail` outranks it.
    func skip(_ reason: String) {
        stepSkipReason = reason
    }

    // MARK: - Live-surface helpers (timeout-guarded, English)

    /// Polls the container's status until it reaches `target` or the
    /// budget runs out, logging every transition with elapsed time.
    /// Activation is fire-and-forget by design, so polling the observed
    /// status IS the user's perspective — and the budget guarantees a
    /// hung transition can never wedge the runner.
    ///
    /// Observer-only, on evidence: the manager's own status observation
    /// keeps `status` current, and a `refreshStatus()` here proved
    /// harmful on the first live run — it stomped the manager's
    /// optimistic `.activating` with the system's stale value and
    /// logged a transition that never happened. The harness observes
    /// shared state, it never writes it.
    @discardableResult
    func awaitStatus(_ tunnel: TunnelContainer, is target: TunnelStatus, within seconds: Double) async -> Bool {
        let start = Date()
        var last = tunnel.status
        while Date().timeIntervalSince(start) < seconds {
            if Task.isCancelled { return false }
            if tunnel.status != last {
                log("status: \(last) → \(tunnel.status) (t=\(Self.elapsed(start)))")
                last = tunnel.status
            }
            if tunnel.status == target { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        log("status stayed \(tunnel.status) — no \(target) within \(Int(seconds))s", .warn)
        return false
    }

    /// Sends one app message to the tunnel extension and races the
    /// reply against a timeout, so a mute extension can never wedge
    /// the runner. `NETunnelProviderSession` RPCs aren't cancellable;
    /// a late reply after a timeout win is simply dropped. Stop
    /// responsiveness is bounded by the in-flight budget — the
    /// timeout sleeper is unstructured and uncancelled by design.
    func providerMessage(_ tunnel: TunnelContainer, _ bytes: [UInt8], timeout: Double = 5) async -> ProviderReply {
        await withCheckedContinuation { continuation in
            let resume = SingleResume(continuation)
            do {
                try tunnel.tunnelProvider.sendProviderMessage(Data(bytes)) { data in
                    resume.finish(data.map(ProviderReply.data) ?? .empty)
                }
            } catch {
                resume.finish(.unanswered)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                resume.finish(.unanswered)
            }
        }
    }

    /// Runs `operation` under a wall-clock ceiling. Returns its value,
    /// or nil if the ceiling wins first — the harness must never await
    /// an app call that itself carries no timeout (a mute extension
    /// would wedge the runner otherwise). The losing operation keeps
    /// running; only its result is dropped.
    func race<T: Sendable>(_ seconds: Double, _ operation: @escaping @MainActor () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resume = SingleResume(continuation)
            Task { @MainActor in resume.finish(await operation()) }
            Task { try? await Task.sleep(for: .seconds(seconds)); resume.finish(nil) }
        }
    }

    private static func elapsed(_ start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }

    // MARK: - Runner entry (not for subclasses)

    func _bind(_ context: TestContext, _ engine: PhantomTestEngine) {
        self.context = context
        self.engine = engine
    }
    func _run() async {
        for step in steps {
            if Task.isCancelled { break }
            stepFailed = false
            stepSkipReason = nil
            engine?.emit("  • \(step.title)", .step)
            await step.body()
            // Fail outranks everything: a failure recorded before a
            // Stop is real evidence and keeps its verdict. Only a
            // cancelled body that had NOT already failed reads SKIP —
            // its remaining claims are unproven, not disproven — and
            // either way a cancelled run proves nothing further.
            if stepFailed {
                engine?.emit("    ✗ FAIL", .error)
                if Task.isCancelled { break }
            } else if Task.isCancelled {
                engine?.emit("    ◦ SKIP (cancelled)", .skip)
                break
            } else if let reason = stepSkipReason {
                engine?.emit("    ◦ SKIP (\(reason))", .skip)
            } else {
                engine?.emit("    ✓ PASS", .ok)
            }
        }
    }
}
#endif
