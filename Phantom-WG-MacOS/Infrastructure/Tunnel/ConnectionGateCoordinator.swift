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
    /// Idempotent; re-entries fall through to `checkAgain()`.
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
    /// — keep the two in lockstep. The gate cannot call it directly
    /// because the engage sweep needs the same providers/owned-set the
    /// verdict was computed from.
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

    private func disarmOwnArmedRules(providers: [TunnelProviding], ownedIDs: Set<UUID>) async {
        for provider in providers where provider.isOnDemandEnabled {
            guard let id = provider.tunnelIdentity?.id, ownedIDs.contains(id) else { continue }
            provider.isOnDemandEnabled = false
            try? await provider.savePreferences()
            NSLog("[slot] gate disarmed recovery on \(provider.localizedDescription ?? id.uuidString)")
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
