#if DEBUG
import Foundation

// Core: the flat output model, the live context (everything the app
// exposes to the user), and the runner. The workflow base class lives in
// TestWorkflow.swift, the workflows under workflows/, their one-line
// registration in TestCatalog. DEBUG-only two ways: this guard and
// project.yml's EXCLUDED_SOURCE_FILE_NAMES.

/// A single output line's kind, for colour and font weight and nothing
/// else. The output is a flat, readable text stream (like the
/// tunnel/split log panels), not a widget tree.
enum OutputKind { case header, rule, step, info, ok, warn, error, skip, result }

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

    /// One runner for the process, not one per sheet.
    ///
    /// The panel is a sheet: closing it destroys the view and every
    /// `@State` it owned. With the runner living there, reopening
    /// built a fresh one whose `isRunning` was false while the
    /// previous run — and its teardown, which rides a context
    /// cancellation cannot reach, by design — was still working
    /// against the same vault and the same single VPN slot. Two runs
    /// over those is precisely what the latch exists to prevent, so
    /// the latch has to outlive the sheet. The output outliving it too
    /// is the welcome part: reopening the panel now shows what the
    /// last run said instead of an empty page.
    static let shared = PhantomTestEngine()
    private init() {}

    private(set) var lines: [OutputLine] = []
    private(set) var isRunning = false

    /// The run in flight. Held here rather than in the view for the
    /// same reason as the latch: Stop has to reach the run even when
    /// it is pressed from a second sheet instance.
    @ObservationIgnored private var runTask: Task<Void, Never>?

    /// Why the suite stopped itself, if it did. Distinct from Stop:
    /// the user did not ask, the run decided that going on would
    /// report something it cannot honestly claim.
    private(set) var abortReason: String?

    /// Called by a workflow that has proven the rest of the run is not
    /// worth printing. First reason wins — a later step should not
    /// overwrite the finding that stopped everything.
    func requestAbort(_ reason: String) {
        // A run already stopping does not need a second reason, and
        // printing one would dress the user's own Stop as a finding —
        // the same discipline `fail` and `check` follow.
        guard !Task.isCancelled, abortReason == nil else { return }
        abortReason = reason
        emit("      suite abort requested: \(reason)", .error)
    }

    func reset() { lines = [] }
    func emit(_ text: String, _ kind: OutputKind) { lines.append(OutputLine(text: text, kind: kind)) }

    /// The full output as plain text — copyable and saveable.
    var plainText: String { lines.map(\.text).joined(separator: "\n") }

    /// Starts a run, or does nothing when one is already in flight.
    ///
    /// The latch is taken HERE, synchronously, before the task exists:
    /// a check made inside the task body would let two taps in the
    /// same runloop turn both through, since neither task has begun.
    func start(_ workflows: [TestWorkflow], _ ctx: TestContext) {
        guard !isRunning else { return }
        isRunning = true
        abortReason = nil
        reset()
        runTask = Task { [weak self] in
            await self?.run(workflows, ctx)
        }
    }

    /// Cancels the run in flight. The workflows' teardown nets still
    /// run to completion afterwards — that is what keeps the machine
    /// clean — so `isRunning` stays true until they finish.
    func stop() { runTask?.cancel() }

    private func run(_ workflows: [TestWorkflow], _ ctx: TestContext) async {
        defer {
            isRunning = false
            runTask = nil
        }
        for (index, workflow) in workflows.enumerated() {
            if Task.isCancelled { break }
            // An abort raised inside the previous workflow stops the
            // suite here — after that workflow's own teardown, which
            // `_run` already ran on its way out.
            if abortReason != nil { break }
            if index > 0 { emit("", .info) }
            emit("▸ \(workflow.displayName)", .header)
            emit(String(repeating: "─", count: 44), .rule)
            workflow._bind(ctx, self)
            await workflow._run()
        }
        emit("", .info)
        // Stop is read first: when the user cancelled a run that had
        // also aborted itself, what ended it was the user. The abort
        // reason is already on its own line above either way.
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
