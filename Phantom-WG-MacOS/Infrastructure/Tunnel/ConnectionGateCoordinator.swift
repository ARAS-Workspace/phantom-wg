import Foundation
import NetworkExtension
import AppKit

/// Third lock in the boot chain: extensions ready → vault session
/// ready → **the system's one VPN slot is not held by another local
/// user** → tunnel content. The system extension and its NE
/// configurations are machine-wide, so a second local account's
/// active session occupies the same exclusive slot this user's
/// tunnels need; activating against it just feeds the cross-user
/// on-demand fight. Rather than pushing the operator into that
/// unhealthy loop, the gate names the situation, stands our own
/// recovery rules down, and waits for the slot to be freed in
/// System Settings > VPN — the one surface that can free it.
///
/// The verdict comes from `SlotClassifier` (shared with the
/// activation belts) and follows its evidence doctrine: only a
/// positively-proven foreign holder engages the gate; anything
/// unverifiable reads as a free slot, so a degraded signal can never
/// falsely imprison the app.
@Observable
@MainActor
final class ConnectionGateCoordinator {

    enum State: Equatable {
        case checking
        case slotFree
        case slotHeld(holderName: String?)
    }

    private(set) var state: State = .checking

    @ObservationIgnored private let providerFactory: TunnelProviderFactory
    @ObservationIgnored private let vault: TunnelVaultClient
    /// How the sweep finds the manager, ASKED at sweep time rather than
    /// handed over once.
    ///
    /// A one-shot handover cannot work here, and the ordering is not a
    /// matter of care but of shape: the manager is created by the view
    /// that renders only once this gate reports `.slotFree`
    /// (`PhantomApp` switches on that state, `TunnelContentView` builds
    /// the manager in its `.task`). So at the sweep that matters most —
    /// the launch-time one, which is the ordinary case when a foreign
    /// session already holds the slot — there is no manager to hand
    /// over at all. A property assigned when one is finally published
    /// reads nil for exactly that sweep, and cannot follow a manager
    /// that is later rebuilt; both times the sweep takes the unbarred
    /// fallback below while this doc claims the bars are in force.
    ///
    /// A closure has no such moment to miss. It is installed before
    /// anything runs and evaluated when the answer is needed, so it is
    /// right whether the manager exists yet or has since been replaced.
    @ObservationIgnored var currentTunnelsManager: (@MainActor () -> TunnelsManager?)?
    @ObservationIgnored private var observationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingCheck: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// Last-STARTED pass wins: evaluate suspends several times (loads,
    /// vault reads, disarm saves) and passes can overlap — a stale
    /// pass settling late would overwrite a fresher verdict and, in
    /// the free-over-held ordering, cancel the very poll that exists
    /// to self-heal. Completions carrying an old epoch are discarded.
    @ObservationIgnored private var evaluationEpoch = 0

    init(
        vault: TunnelVaultClient,
        providerFactory: TunnelProviderFactory = RealTunnelProviderFactory(),
        initialState: State = .checking
    ) {
        self.vault = vault
        self.providerFactory = providerFactory
        self.state = initialState
    }

    deinit {
        observationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        pendingCheck?.cancel()
        pollTask?.cancel()
    }

    /// Arms the observers and runs the first check. Called when the
    /// vault session reaches `.ready` — the verdict needs the vault to
    /// answer ownership, so checking earlier could only be inconclusive.
    /// Idempotent; later calls are plain no-ops, so every return to
    /// vault-readiness must pair `start()` with `checkAgain()` (the
    /// `.task(id:)` in `PhantomApp` does exactly that).
    func start() {
        guard !started else { return }
        started = true
        observe(.NEVPNConfigurationChange)
        observe(.NEVPNStatusDidChange)
        observe(NSApplication.didBecomeActiveNotification)
        scheduleCheck(immediate: true)
    }

    /// Manual re-check (the gate's button) and the fresh-verdict entry
    /// for every return to vault-readiness.
    func checkAgain() {
        scheduleCheck(immediate: true)
    }

    /// One evaluation pass, run to completion — the deterministic
    /// entry the DEBUG harness drives directly (the notification path
    /// is debounced and unfit for a step's verdict).
    func evaluateNow() async {
        await evaluate()
    }

    // MARK: - Private

    private func observe(_ name: Notification.Name) {
        observationTokens.append(NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleCheck() }
        })
    }

    /// Trailing-edge debounce over the notification bursts — the same
    /// 400ms window the tunnel manager's refresh uses.
    private func scheduleCheck(immediate: Bool = false) {
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            await self?.evaluate()
        }
    }

    /// Mirrors `TunnelsManager.foreignSlotVerdict()`'s funnel (loadAll
    /// → owner-scoped readAll → classifier, unverifiable answers free)
    /// with one deliberate divergence: NO deadline here. The manager's
    /// user-facing verdict callers — the rung-0 pre-flight and the
    /// start-catch — opt into a tight budget because a user is
    /// waiting; the gate is the patient path and must wait out slow
    /// evidence — do not "fix" this copy by adding the deadline. The
    /// gate cannot call the manager's directly because the engage
    /// sweep needs the same providers/owned-set the verdict was
    /// computed from.
    private func evaluate() async {
        evaluationEpoch += 1
        let epoch = evaluationEpoch

        guard let providers = try? await providerFactory.loadAllFromPreferences(),
              case .configs(let mine) = await vault.readAll() else {
            // Unverifiable is not "held" — never block on evidence
            // that did not arrive.
            guard epoch == evaluationEpoch else { return }
            settle(.slotFree)
            return
        }
        let ownedIDs = Set(mine.map(\.id))
        let verdict = await SlotClassifier.classify(providers: providers, ownedIDs: ownedIDs) { id in
            await self.vault.read(id: id)
        }
        guard epoch == evaluationEpoch else { return }
        switch verdict {
        case .free:
            settle(.slotFree)
        case .heldByForeign(let name):
            // Entering the gate completes the stand-down properly:
            // our armed connect-on-any-network rules are what feed
            // the cross-user fight, so they go quiet before we ask
            // the user for anything. Idempotent — the poll re-runs
            // this only over rules that are still armed.
            await disarmOwnArmedRules(providers: providers, ownedIDs: ownedIDs)
            guard epoch == evaluationEpoch else { return }
            settle(.slotHeld(holderName: name))
        }
    }

    /// The gate's stand-down, now through the same gate every other
    /// deferred disarm uses.
    ///
    /// What it used to do wrong was the reporting: it lowered the flag,
    /// spent the save under a `try?`, and then logged "disarmed"
    /// whatever the system answered. What it also did wrong, and less
    /// visibly, was carry neither liveness bar — and this is the site
    /// that runs while a foreign session holds the slot, which is
    /// exactly when a user is likely to be deleting the tunnel that
    /// will not connect. A save landing on an entry that removal has
    /// just taken re-mints it, invisible and undeletable. Routing
    /// through `standDownForSlotGate` buys the bars, the single refusal
    /// sentence, and a write through the manager's own provider instead
    /// of this pass's copy of it.
    ///
    /// The armed FILTER stays, and the reason is not the one written
    /// here before. That reason said the flag is fresh because these
    /// providers came from a system read in this same pass — but the
    /// pass suspends between that read and this loop: the bulk vault
    /// read, and then a per-id probe for each OCCUPYING provider the
    /// owned set does not claim (not one per unmatched provider, which
    /// is the count this sentence used to give). One probe is enough
    /// for the flag to be seconds old. The cost of that staleness is
    /// bounded and small: a rule armed inside the gap is skipped once
    /// and caught by the poll a few seconds later.
    ///
    /// What the filter actually buys is TERMINATION, and without it
    /// this method does not terminate. `standDownRecovery` saves
    /// unconditionally, a landed save broadcasts a configuration
    /// change, and this coordinator listens for exactly that — so an
    /// unfiltered sweep would save, wake itself 400ms later, still find
    /// the slot held, and save again, for as long as the foreign
    /// session lasts. The filter breaks that loop because each pass
    /// re-reads the system list and a disarmed rule drops out of it. Do
    /// not remove this filter for consistency with its siblings; their
    /// reasons are about staleness, and this one is about a loop.
    private func disarmOwnArmedRules(providers: [TunnelProviding], ownedIDs: Set<UUID>) async {
        for provider in providers where provider.isOnDemandEnabled {
            guard let id = provider.tunnelIdentity?.id, ownedIDs.contains(id) else { continue }
            let name = provider.localizedDescription ?? id.uuidString
            guard let manager = currentTunnelsManager?() else {
                // Two ways in, and the same fact makes both safe — but
                // the fact is about REMOVALS, not about existence: no
                // manager is reachable from any view, so no `remove()`
                // can have been issued through one, so the bars this
                // write is missing would refuse nothing. (A manager
                // object can exist here, mid-creation, with a fully
                // materialized list; what it cannot have is a removal
                // in flight.) Either the supplier was never installed
                // (previews, a step building a bare gate), or it has
                // been and answers nil because nothing is published. Once one IS
                // published the closure answers and this branch stops
                // being taken — the one thing a property assigned at a
                // single moment could not offer, since no such moment
                // exists here.
                if let error = await TunnelsManager.standDownRecovery(on: provider) {
                    NSLog("[slot] gate could not disarm recovery on \(name), written without the removal bars — armed=\(provider.isOnDemandEnabled) is the truest reading available: \(error.localizedDescription)")
                } else {
                    // Said differently from the routed line below on
                    // purpose: the one thing this package changed about
                    // a successful disarm is WHICH object it went
                    // through, and a field log that spells both the same
                    // way cannot answer the only question a report about
                    // a re-minted entry would ask.
                    NSLog("[slot] gate disarmed recovery on \(name) — no manager yet, written without the removal bars")
                }
                continue
            }
            switch await manager.standDownForSlotGate(id: id, context: "at the connection gate, over a proven foreign holder") {
            case .done:
                NSLog("[slot] gate disarmed recovery on \(name)")
            case .barred:
                NSLog("[slot] gate left \(name) alone: it is being removed, or the list no longer holds it")
            case .refused:
                // The refusal is already reported, in the one format
                // every disarm site shares — but a reader following the
                // `[slot]` narrative would otherwise watch this row
                // vanish between an engage and a release with nothing
                // said about it. One line naming the outcome, pointing
                // at that report rather than copying it: a second copy
                // of the error text here is exactly the drift the shared
                // format exists to prevent.
                NSLog("[slot] gate could not disarm recovery on \(name) — the save was refused, reported above")
            }
        }
    }

    private func settle(_ new: State) {
        if state != new {
            NSLog("[slot] \(String(describing: state)) -> \(String(describing: new))")
        }
        state = new
        // The foreign session's own transitions may never notify this
        // process — a slow poll while held is the belt that releases
        // the gate the moment System Settings frees the slot.
        pollTask?.cancel()
        pollTask = nil
        if case .slotHeld = new {
            pollTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await self?.evaluate()
            }
        }
    }
}
