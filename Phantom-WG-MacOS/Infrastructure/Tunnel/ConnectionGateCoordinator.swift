import Foundation
import NetworkExtension
import AppKit

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
    @ObservationIgnored var currentTunnelsManager: (@MainActor () -> TunnelsManager?)?
    @ObservationIgnored private var observationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingCheck: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var evaluationEpoch = 0
    @ObservationIgnored private var heldProviders: [TunnelProviding] = []
    @ObservationIgnored private var ownedIDs: Set<UUID> = []
    @ObservationIgnored private var reloadPending = false
    @ObservationIgnored private var reloadsInFlight = 0
    @ObservationIgnored private var isShutDown = false

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

    /// @witness ConnectionGate
    func start() {
        guard !started, !isShutDown else { return }
        started = true
        observeReloadTrigger(.NEVPNConfigurationChange)
        observeReloadTrigger(NSApplication.didBecomeActiveNotification)
        observeHeldSessions()
        scheduleCheck(reload: true, immediate: true)
    }

    func checkAgain() {
        scheduleCheck(reload: true, immediate: true)
    }

    /// @witness RuntimeShutdown
    func shutDown() {
        isShutDown = true
        observationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        observationTokens.removeAll()
        pendingCheck?.cancel()
        pendingCheck = nil
        pollTask?.cancel()
        pollTask = nil
    }

#if DEBUG
    /// @witness Isolation
    func evaluateNow() async {
        await reload()
    }
#endif

    // MARK: - Private

    private func observeReloadTrigger(_ name: Notification.Name) {
        observationTokens.append(NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleCheck(reload: true) }
        })
    }

    private func observeHeldSessions() {
        observationTokens.append(NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, self.heldProviders.contains(where: { $0.matchesNotification(notification) }) else { return }
                self.scheduleCheck(reload: false)
            }
        })
    }

    private func scheduleCheck(reload: Bool, immediate: Bool = false) {
        guard !isShutDown else { return }
        if reload { reloadPending = true }
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled, let self else { return }
            if self.reloadPending {
                self.reloadPending = false
                await self.reload()
            } else {
                await self.reclassify()
            }
        }
    }

    private func reload() async {
        evaluationEpoch += 1
        let epoch = evaluationEpoch
        reloadsInFlight += 1
        defer { reloadsInFlight -= 1 }

        guard let providers = try? await providerFactory.loadAllFromPreferences() else {
            guard epoch == evaluationEpoch else { return }
            settle(.slotFree)
            return
        }
        guard epoch == evaluationEpoch else { return }
        heldProviders = providers
        guard case .configs(let mine) = await vault.readAll() else {
            guard epoch == evaluationEpoch else { return }
            settle(.slotFree)
            return
        }
        guard epoch == evaluationEpoch else { return }
        ownedIDs = Set(mine.map(\.id))
        await classify(epoch: epoch)
    }

    private func reclassify() async {
        guard reloadsInFlight == 0 else { return }
        evaluationEpoch += 1
        await classify(epoch: evaluationEpoch)
    }

    private func classify(epoch: Int) async {
        let providers = heldProviders
        let owned = ownedIDs
        let verdict = await SlotClassifier.classify(providers: providers, ownedIDs: owned) { id in
            await self.vault.read(id: id)
        }
        guard epoch == evaluationEpoch else { return }
        switch verdict {
        case .free:
            settle(.slotFree)
        case .heldByForeign(let name):
            await disarmOwnArmedRules(providers: providers, ownedIDs: owned)
            guard epoch == evaluationEpoch else { return }
            settle(.slotHeld(holderName: name))
        }
    }

    private func disarmOwnArmedRules(providers: [TunnelProviding], ownedIDs: Set<UUID>) async {
        for provider in providers where provider.isOnDemandEnabled {
            guard let id = provider.tunnelIdentity?.id, ownedIDs.contains(id) else { continue }
            let name = provider.localizedDescription ?? id.uuidString
            guard let manager = currentTunnelsManager?() else {
                switch await TunnelsManager.standDownRecovery(on: provider) {
                case .done:
                    NSLog("[slot] gate disarmed recovery on \(name) — no manager yet, written without the removal bars")
                case .refused(let error):
                    NSLog("[slot] gate could not disarm recovery on \(name), written without the removal bars — the flag holds this write (disarmed); the store keeps whatever the refusal left until the next load: \(error.localizedDescription)")
                case .unanswered:
                    NSLog("[slot] gate's disarm save on \(name) has not answered — left running, nothing decided on it")
                }
                continue
            }
            switch await manager.standDownForSlotGate(id: id, context: "at the connection gate, over a proven foreign holder") {
            case .done:
                NSLog("[slot] gate disarmed recovery on \(name)")
            case .barred:
                NSLog("[slot] gate left \(name) alone: it is being removed, or the list no longer holds it")
            case .refused:
                NSLog("[slot] gate could not disarm recovery on \(name) — the save was refused, reported above")
            case .unanswered:
                NSLog("[slot] gate's disarm save on \(name) has not answered — left running, nothing decided on it")
            }
        }
    }

    /// @witness ConnectionGate.heldReloadsAtBeltPace
    private func settle(_ new: State) {
        if state != new {
            NSLog("[slot] \(String(describing: state)) -> \(String(describing: new))")
            state = new
            pollTask?.cancel()
            pollTask = nil
        }
        guard case .slotHeld = new, pollTask == nil, !isShutDown else { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.pollTask = nil
            await self.reload()
        }
    }
}
