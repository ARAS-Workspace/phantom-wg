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

    func start() {
        guard !started else { return }
        started = true
        observe(.NEVPNConfigurationChange)
        observe(.NEVPNStatusDidChange)
        observe(NSApplication.didBecomeActiveNotification)
        scheduleCheck(immediate: true)
    }

    func checkAgain() {
        scheduleCheck(immediate: true)
    }

#if DEBUG
    /// @witness Isolation
    func evaluateNow() async {
        await evaluate()
    }
#endif

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

    private func scheduleCheck(immediate: Bool = false) {
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            await self?.evaluate()
        }
    }

    private func evaluate() async {
        evaluationEpoch += 1
        let epoch = evaluationEpoch

        guard let providers = try? await providerFactory.loadAllFromPreferences(),
              case .configs(let mine) = await vault.readAll() else {
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
            await disarmOwnArmedRules(providers: providers, ownedIDs: ownedIDs)
            guard epoch == evaluationEpoch else { return }
            settle(.slotHeld(holderName: name))
        }
    }

    private func disarmOwnArmedRules(providers: [TunnelProviding], ownedIDs: Set<UUID>) async {
        for provider in providers where provider.isOnDemandEnabled {
            guard let id = provider.tunnelIdentity?.id, ownedIDs.contains(id) else { continue }
            let name = provider.localizedDescription ?? id.uuidString
            guard let manager = currentTunnelsManager?() else {
                if let error = await TunnelsManager.standDownRecovery(on: provider) {
                    NSLog("[slot] gate could not disarm recovery on \(name), written without the removal bars — armed=\(provider.isOnDemandEnabled) is the truest reading available: \(error.localizedDescription)")
                } else {
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
                NSLog("[slot] gate could not disarm recovery on \(name) — the save was refused, reported above")
            }
        }
    }

    private func settle(_ new: State) {
        if state != new {
            NSLog("[slot] \(String(describing: state)) -> \(String(describing: new))")
        }
        state = new
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
