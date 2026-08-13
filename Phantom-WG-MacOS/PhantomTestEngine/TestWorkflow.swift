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

    /// How long an activation may honestly take, read from the ladder
    /// instead of guessed: every rung the manager will climb, at its
    /// own pacing. A step that waits less than this and then fails is
    /// not measuring the tunnel, it is measuring its own impatience —
    /// a slow but correct connect would print red.
    var activationBudget: Double {
        Double(tunnels.maxRetries) * tunnels.retryInterval
    }

    /// Stops the whole suite after this step, for the one case where
    /// continuing would be dishonest rather than merely slow: the
    /// verdicts below would describe something other than what is
    /// installed. Everything already reported keeps its verdict, and
    /// the teardown nets still run.
    func abortRun(_ reason: String) {
        engine?.requestAbort(reason)
    }

    // MARK: - Step helpers (English, indented under the current step)

    func log(_ text: String, _ level: OutputKind = .info) {
        engine?.emit("      \(text)", level)
    }
    /// Records a failure — unless the run is already stopping.
    ///
    /// Some live-surface helpers unwind with a negative answer the
    /// moment Stop lands (`awaitStatus` returns false, and
    /// `vault.delete(id:attempts:)` refuses to send a single request),
    /// and a body that turns that answer into `fail` would print a red
    /// regression the user themselves caused. Others — `providerMessage`
    /// and `race` — never see the cancellation at all and keep
    /// returning real observations, which is why this guard is about
    /// WHEN the verdict lands, not about where the answer came from. A failure recorded
    /// BEFORE the Stop still stands: `stepFailed` is already set by
    /// then, and nothing here clears it.
    ///
    /// The cut-off is when the verdict is RECORDED, not when the fact
    /// was observed — a negative that was already certain before the
    /// Stop still reads "unproven" if the call lands after it. That is
    /// the safe direction to be wrong in: a suppressed true failure
    /// costs one re-run, an invented one costs a bug hunt.
    func fail(_ message: String? = nil) {
        if Task.isCancelled {
            if let message { log("\(message) — unproven, run stopped", .skip) }
            return
        }
        stepFailed = true
        if let message { log(message, .error) }
    }
    /// Logs the outcome (ok/error) and fails the step when false.
    ///
    /// After a Stop this goes quiet in BOTH directions: a negative is
    /// unproven rather than disproven, and a positive is unearned
    /// rather than proven. The asymmetric version of this guard (mute
    /// the reds, keep printing the greens) reads worst of all — an
    /// invariant that "held" because every observation behind it was
    /// cut short.
    @discardableResult
    func check(_ condition: Bool, _ message: String) -> Bool {
        if Task.isCancelled {
            log("\(message) — unproven, run stopped", .skip)
            return condition
        }
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
    /// Observer-only: the manager's own status observation keeps
    /// `status` current, so a `refreshStatus()` from inside this loop
    /// would add a second writer to reason about for no reading it does
    /// not already have. On the first live run it did worse than that —
    /// it stomped the manager's optimistic `.activating` and logged a
    /// transition that never happened — though that particular stomp is
    /// no longer possible from anywhere: `TunnelContainer.refreshStatus`
    /// now refuses to lower a row the manager is driving, which
    /// `ActivationSeamWorkflow`'s two refresh steps assert.
    ///
    /// Those two steps are the only place the suite calls a status
    /// writer at all, and both call it on a side-manager container the
    /// step built itself over synthetic providers — no container the
    /// app is using has its status written by the suite. Elsewhere the
    /// suite still writes: activation bookkeeping is arranged directly
    /// in a couple of seam steps, every workflow drives the manager's
    /// own entry points, and this file itself hands out the raw vault
    /// write surface and a provider-message sender. The narrow claim
    /// is the one that matters here — nothing observes a tunnel's
    /// status by writing it.
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
    ///
    /// Stop does not reach the operation: both sides ride unstructured
    /// tasks, which inherit actor and priority but not cancellation.
    /// That is load-bearing for `onTeardown` — cleanup has to survive
    /// the very cancellation that makes it necessary — and it is why
    /// Stop responsiveness here is bounded by `seconds`, not immediate.
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

    // MARK: - Teardown (residue net)

    /// Registers cleanup for residue this workflow plants in shared
    /// state — a vault payload, a system entry, a tunnel left running.
    ///
    /// The suite's own sweep steps stay where they are: they are the
    /// owners on the normal path and their verdicts are real evidence.
    /// This is the net under them, for the paths a step never reaches:
    /// a Stop mid-body, an early `return`, a precondition skip. Under a
    /// Stop the owning step cannot sweep even if it is reached —
    /// `vault.delete(id:attempts:)` returns false without sending a
    /// request once the task is cancelled — so on that path the net is
    /// not a second chance, it is the only one.
    ///
    /// Two rules for bodies. They must tolerate running after the
    /// owning step already swept (look before deleting, and stay quiet
    /// about what is already gone), and each must report exactly one
    /// result line, including "nothing to sweep" — a silent net cannot
    /// be told from a net that never ran.
    ///
    /// Jobs run in reverse registration order (innermost residue
    /// first), each under its own ceiling, in a context Stop cannot
    /// reach — see `race`. One consequence to keep in mind if a body
    /// ever grows an assertion: inside it `Task.isCancelled` is false,
    /// so `check` and `fail` behave normally even though the run is
    /// stopping. Report with `log`; the nets are cleanup, not claims.
    func onTeardown(_ label: String, _ body: @escaping @MainActor () async -> Void) {
        teardowns.append((label, body))
    }

    private var teardowns: [(label: String, body: @MainActor () async -> Void)] = []

    /// Sized for the single-residue bodies: grounding a live tunnel is
    /// 15s, and `remove()` behind it can spend a 5s transport timeout
    /// plus 600/1200ms backoffs on each of three vault attempts, about
    /// 17s more.
    ///
    /// A body that loops over many ids can still exceed this against a
    /// dark vault — the vault-throwaway net is the one that can, which
    /// is why that net stops itself at the first unreachable read
    /// rather than relying on the ceiling. Ceilings here are a backstop
    /// for a wedged call, not a budget the bodies may spend freely.
    ///
    /// And the ceiling drops the RESULT, not the work (see `race`): a
    /// job past it keeps running detached, so the warning below means
    /// "this run stopped waiting", not "this cleanup was cancelled".
    /// A run that ends that way can report done while a sweep is still
    /// going, so the bodies stay bounded on their own.
    private static let teardownCeiling: Double = 45

    private func runTeardowns() async {
        guard !teardowns.isEmpty else { return }
        let jobs = Array(teardowns.reversed())
        teardowns.removeAll()
        engine?.emit("  • Teardown", .step)
        for job in jobs {
            let finished: Void? = await race(Self.teardownCeiling) { await job.body() }
            if finished == nil {
                engine?.emit("      \(job.label): still running past \(Int(Self.teardownCeiling))s — this run stopped waiting for it", .warn)
            }
        }
    }

    // MARK: - Runner entry (not for subclasses)

    // The leading underscore is the deliberate marker that these two
    // belong to the RUNNER: a step body has no business calling
    // either, and the name says so at every call site. The linter's
    // naming rule is right in general and overruled here on purpose.
    // swiftlint:disable:next identifier_name
    func _bind(_ context: TestContext, _ engine: PhantomTestEngine) {
        self.context = context
        self.engine = engine
    }
    // swiftlint:disable:next identifier_name
    func _run() async {
        for step in steps {
            if Task.isCancelled { break }
            if engine?.abortReason != nil { break }
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
        // Always, including the `break` paths above: the net exists
        // precisely for the runs that ended early.
        await runTeardowns()
    }
}
#endif
