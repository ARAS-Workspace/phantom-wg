import Foundation
import AppKit
import NetworkExtension

// swiftlint:disable file_length

@Observable
@MainActor
// swiftlint:disable:next type_body_length
class TunnelsManager {

    var tunnels: [TunnelContainer] = []

    @ObservationIgnored private let providerFactory: TunnelProviderFactory
    @ObservationIgnored let vault: TunnelVaultClient

    @ObservationIgnored let currentUser: uid_t
    @ObservationIgnored private var statusObservationToken: AnyObject?
    @ObservationIgnored private var configObservationToken: AnyObject?
    @ObservationIgnored private var foregroundObservationToken: AnyObject?

    @ObservationIgnored private var isReconciling = false

    @ObservationIgnored private var creatingIds: Set<UUID> = []

    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    @ObservationIgnored private(set) var refreshSuspended = false

    @ObservationIgnored private var restoreBarredByTeardown = false

    @ObservationIgnored var waitingTunnel: TunnelContainer?

    let retryInterval: TimeInterval
    let maxRetries: Int

    let preflightBudget: TimeInterval = 2

    var activationCeiling: TimeInterval {
        Double(maxRetries + 1) * retryInterval + preflightBudget
    }

    @ObservationIgnored private(set) var removingIds: Set<UUID> = []

    // MARK: - Factory

    static func create(vault: TunnelVaultClient) async throws -> TunnelsManager {
        let factory = RealTunnelProviderFactory()
        let providers = try await factory.loadAllFromPreferences()
        let manager = TunnelsManager(tunnelProviders: [], providerFactory: factory, vault: vault)
        await manager.ingest(providers)
        return manager
    }

    init(
        tunnelProviders: [TunnelProviding],
        providerFactory: TunnelProviderFactory = RealTunnelProviderFactory(),
        vault: TunnelVaultClient,
        currentUser: uid_t = getuid(),
        retryInterval: TimeInterval = 5.0,
        maxRetries: Int = 8,
        observesSystemChanges: Bool = true
    ) {
        self.providerFactory = providerFactory
        self.vault = vault
        self.currentUser = currentUser
        self.retryInterval = retryInterval
        self.maxRetries = maxRetries
        tunnels = Self.sortedByCreatedAt(tunnelProviders.map { TunnelContainer(tunnel: $0) })
        startObservingTunnelStatuses()
        if observesSystemChanges {
            startObservingTunnelConfigurations()
            startObservingForeground()
        }
    }

    static func sortedByCreatedAt(_ list: [TunnelContainer]) -> [TunnelContainer] {
        list.sorted {
            let lhs = $0.identity?.createdAt ?? .distantPast
            let rhs = $1.identity?.createdAt ?? .distantPast
            return lhs > rhs
        }
    }

    deinit {
        pendingRefresh?.cancel()
        if let token = statusObservationToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = configObservationToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = foregroundObservationToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - CRUD

    /// @witness Unreachable
    /// @witness VaultIntegrity
    func add(config: TunnelConfig) async throws -> TunnelContainer {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw TunnelManagementError.tunnelInvalidName
        }
        if tunnels.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw TunnelManagementError.tunnelAlreadyExistsWithThatName
        }

        try await purgeVaultDuplicates(of: config)

        creatingIds.insert(config.id)
        defer { creatingIds.remove(config.id) }

        if let failure = TunnelManagementError.forVaultWrite(await vault.store(config, attempts: 3)) {
            throw failure
        }

        do {
            return try await createEntry(for: config)
        } catch {
            let rollback = await vault.delete(id: config.id, attempts: 3)
            if let residue = TunnelManagementError.forVaultWrite(rollback) {
                NSLog("[add] rollback of \(config.name) left its payload behind — \(residue.localizedDescription). A later reconcile may mint the entry this add reported as failed")
            }
            throw error
        }
    }

    // MARK: - Reconcile

    /// @witness VaultIntegrity
    /// @witness VaultIntegrity.theUninstallsRemovalIsNotUndoneByTheRestore
    @discardableResult
    func reconcileFromVault() async -> Int {
        guard !isReconciling else { return 0 }
        isReconciling = true
        defer { isReconciling = false }

        guard case .configs(let payloads) = await vault.readAll() else {
            NSLog("[vault] reconcile skipped — the vault did not answer")
            return 0
        }

        let known = Set(tunnels.map(\.id))
        let candidates = payloads.filter {
            !known.contains($0.id)
                && !creatingIds.contains($0.id)
                && !removingIds.contains($0.id)
        }

        if restoreBarredByTeardown {
            if !candidates.isEmpty {
                NSLog("[vault] reconcile minted nothing for \(candidates.count) payload(s): this process took their entries in a teardown and kept the secrets")
            }
            await realignDriftedProjections(with: payloads, skipping: [])
            return 0
        }

        let missing = candidates.sorted { $0.createdAt < $1.createdAt }

        let candidateIds = Set(missing.map(\.id))
        creatingIds.formUnion(candidateIds)
        defer { creatingIds.subtract(candidateIds) }

        let (restored, attempted) = await mintMissingEntries(from: missing)

        guard !refreshSuspended else { return restored }
        await realignDriftedProjections(with: payloads, skipping: attempted)

        if restored > 0 {
            NSLog("[vault] reconcile restored \(restored) tunnel(s) the system had lost")
        }
        return restored
    }

    private func listAdmits(_ current: TunnelConfig) -> Bool {
        guard !tunnels.contains(where: { $0.id == current.id }) else {
            NSLog("[vault] reconcile skipped \(current.id): the list took that id while the payload was being proven")
            return false
        }
        guard !removingIds.contains(current.id) else {
            NSLog("[vault] reconcile skipped \(current.id): a removal took the tunnel while the payload was being proven")
            return false
        }
        let name = current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tunnels.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            NSLog("[vault] reconcile skipped \(current.id): a tunnel named '\(name)' already exists")
            return false
        }
        return true
    }

    private enum ProvenPayload {
        case mint(TunnelConfig)
        case skip
        case dark
    }

    private func provePayload(_ config: TunnelConfig) async -> ProvenPayload {
        switch await vault.read(id: config.id) {
        case .config(let fresh):
            guard fresh.id == config.id else {
                NSLog("[vault] reconcile skipped \(config.id): the payload under that key carries a different id (\(fresh.id))")
                return .skip
            }
            return .mint(fresh)
        case .missing:
            NSLog("[vault] reconcile skipped \(config.id): the payload is gone — the snapshot predates its removal")
            return .skip
        case .undecodable:
            NSLog("[vault] reconcile skipped \(config.id): the payload no longer decodes — its entry would project a name the vault can no longer back")
            return .skip
        case .unreachable:
            return .dark
        }
    }

    private func mintMissingEntries(from missing: [TunnelConfig]) async -> (restored: Int, attempted: Set<UUID>) {
        var restored = 0
        var attempted: Set<UUID> = []
        var vaultWentDark = false
        for (index, config) in missing.enumerated() where !vaultWentDark {
            guard !refreshSuspended else {
                NSLog("[vault] reconcile stopped minting at \(config.id): a teardown took the store — \(missing.count - index) candidate(s) left unminted")
                break
            }
            guard !tunnels.contains(where: { $0.id == config.id }) else { continue }

            let current: TunnelConfig
            switch await provePayload(config) {
            case .mint(let fresh):
                current = fresh
            case .skip:
                continue
            case .dark:
                vaultWentDark = true
                NSLog("[vault] reconcile stopped minting at \(config.id): the vault went dark — \(missing.count - index - 1) further candidate(s) left unproven, for whichever trigger reconciles next")
                continue
            }

            guard listAdmits(current) else { continue }

            attempted.insert(current.id)
            do {
                _ = try await createEntry(for: current)
                restored += 1
            } catch {
                NSLog("[vault] reconcile failed for \(config.id): \(error.localizedDescription)")
            }
        }
        return (restored, attempted)
    }

    private func realignDriftedProjections(
        with payloads: [TunnelConfig],
        skipping attempted: Set<UUID>
    ) async {
        for config in payloads where !attempted.contains(config.id) {
            guard !refreshSuspended else {
                NSLog("[vault] realign stopped at \(config.id): a teardown took the store")
                return
            }
            guard let tunnel = tunnels.first(where: { $0.id == config.id }),
                  tunnel.status == .inactive,
                  let projected = tunnel.tunnelProvider.tunnelIdentity,
                  projected.name != config.name || projected.isGhost != config.isGhostMode
            else { continue }

            let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tunnels.contains(where: {
                $0.id != config.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                NSLog("[vault] reconcile skipped realigning \(config.id): a tunnel named '\(name)' already exists")
                continue
            }

            guard mayWriteStore(tunnel) else {
                NSLog("[vault] reconcile skipped realigning \(config.id): the row is no longer this manager's to write")
                continue
            }

            tunnel.tunnelProvider.localizedDescription = config.name
            tunnel.tunnelProvider.configure(with: config.identity)
            do {
                try await tunnel.tunnelProvider.savePreferences()
                try await tunnel.tunnelProvider.loadPreferences()
                tunnel.name = config.name
                NSLog("[vault] reconcile realigned \(config.id): the projection had gone stale")
            } catch {
                try? await tunnel.tunnelProvider.loadPreferences()
                NSLog("[vault] reconcile could not realign \(config.id): \(error.localizedDescription)")
            }
        }
    }

    private func purgeVaultDuplicates(of config: TunnelConfig) async throws {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard case .configs(let payloads) = await vault.readAll() else {
            throw TunnelManagementError.vaultUnavailable
        }

        for other in payloads where other.id != config.id {
            let otherName = other.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard otherName.caseInsensitiveCompare(name) == .orderedSame else { continue }
            guard !tunnels.contains(where: { $0.id == other.id }) else {
                NSLog("[vault] kept payload \(other.id) claiming the name '\(name)': it belongs to a listed tunnel")
                continue
            }
            guard !creatingIds.contains(other.id) else {
                NSLog("[vault] kept payload \(other.id) claiming the name '\(name)': its entry is being created, or a restore pass is deciding about it")
                continue
            }
            let dropped = await vault.delete(id: other.id, attempts: 3)
            if let failure = TunnelManagementError.forVaultWrite(dropped) {
                NSLog("[vault] could not drop stale payload \(other.id) claiming '\(name)': outcome=\(dropped.label)")
                throw failure
            }
            NSLog("[vault] dropped stale payload \(other.id) that claimed the name '\(name)'")
        }
    }

    private func createEntry(for config: TunnelConfig) async throws -> TunnelContainer {
        let provider = providerFactory.makeProvider()
        provider.localizedDescription = config.name
        provider.isEnabled = true
        provider.configure(with: config.identity)

        do {
            try await provider.savePreferences()
            try await provider.loadPreferences()
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnAddTunnel(systemError: error)
        }

        if let listed = tunnels.first(where: { $0.id == config.id }) {
            NSLog("[vault] entry \(config.id) was listed while it was being created — the ingest's row stands")
            return listed
        }

        let tunnel = TunnelContainer(tunnel: provider)
        tunnels.append(tunnel)
        tunnels = Self.sortedByCreatedAt(tunnels)
        return tunnel
    }

    // MARK: - Modify & Remove

    /// @witness TunnelEdit
    /// @witness VaultIntegrity
    func modify(tunnel: TunnelContainer, with config: TunnelConfig) async throws {
        guard !removingIds.contains(tunnel.id) else {
            throw TunnelManagementError.vpnSystemErrorOnModifyTunnel(
                systemError: Self.noSystemDetail(LocalizationManager.shared.t("error_detail_session_ended")))
        }
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw TunnelManagementError.tunnelInvalidName
        }
        if tunnels.contains(where: {
            $0.id != tunnel.id
                && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            throw TunnelManagementError.tunnelAlreadyExistsWithThatName
        }

        try await purgeVaultDuplicates(of: config)

        if let failure = TunnelManagementError.forVaultWrite(await vault.store(config, attempts: 3)) {
            throw failure
        }

        tunnel.tunnelProvider.localizedDescription = name
        tunnel.tunnelProvider.isEnabled = true
        tunnel.tunnelProvider.configure(with: config.identity)

        do {
            try await tunnel.tunnelProvider.savePreferences()
            try await tunnel.tunnelProvider.loadPreferences()
        } catch {
            try? await tunnel.tunnelProvider.loadPreferences()
            throw TunnelManagementError.vpnSystemErrorOnModifyTunnel(systemError: error)
        }

        tunnel.name = name
    }

    /// @witness ActivationSeam
    /// @witness ConfigContract
    /// @witness Isolation
    /// @witness TunnelEdit
    /// @witness Unreachable
    /// @witness VaultIntegrity
    /// @adr 0009
    func remove(tunnel: TunnelContainer) async throws {
        guard !removingIds.contains(tunnel.id) else { return }
        removingIds.insert(tunnel.id)
        defer { removingIds.remove(tunnel.id) }
        let rungSettled: Bool? = await bounded(20) {
            await tunnel.activationRungTask?.value
            await tunnel.pendingDisarmTask?.value
            return true
        }
        guard rungSettled == true else {
            throw TunnelManagementError.vpnSystemErrorOnRemoveTunnel(
                systemError: Self.noSystemDetail(LocalizationManager.shared.t("error_detail_timeout")))
        }
        let entryFirst = try await entryGoesFirst(for: tunnel)

        if !entryFirst {
            if let failure = TunnelManagementError.forVaultWrite(await vault.delete(id: tunnel.id, attempts: 3)) {
                throw failure
            }
        }

        tunnel.isAttemptingActivation = false
        tunnel.activationAttemptId = nil
        tunnel.activationTask?.cancel()
        tunnel.activationTask = nil
        tunnel.respawnReviveConsumed = true
        tunnel.respawnReviveTask?.cancel()
        tunnel.respawnReviveTask = nil
        tunnel.standDownCeiling()

        if let disarmError = await Self.standDownRecovery(on: tunnel.tunnelProvider) {
            NSLog("[remove] disarm save refused on \(tunnel.name) — armed=\(tunnel.tunnelProvider.isOnDemandEnabled) is the truest reading available: \(disarmError.localizedDescription)")
        }

        do {
            try await tunnel.tunnelProvider.removePreferences()
        } catch {
            if entryFirst { tunnel.refreshStatus() }
            throw TunnelManagementError.vpnSystemErrorOnRemoveTunnel(systemError: error)
        }

        if entryFirst {
            if let failure = TunnelManagementError.forVaultWrite(await vault.delete(id: tunnel.id, attempts: 3)) {
                scheduleRefresh()
                throw failure
            }
        }

        retireFromListAndQueue(tunnel)
    }

    private func retireFromListAndQueue(_ tunnel: TunnelContainer) {
        if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            tunnels.remove(at: index)
        }
        if waitingTunnel?.id == tunnel.id {
            waitingTunnel = nil
        }
        activateWaitingTunnelIfNeeded()
    }

    // MARK: - Uninstall

    /// @witness VaultIntegrity.aTeardownThatTookTheStoreStopsTheRestore
    /// @witness VaultIntegrity.realignStandsDownWhenATeardownTakesTheStore
    func suspendRefreshForUninstall() {
        refreshSuspended = true
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    #if DEBUG
    var isStoreHeldForTeardown: Bool { refreshSuspended }
    #endif

    /// Giving the store back has to re-open the questions the bar parked while
    /// it was held. A queue slot is the one that cannot re-ask itself: the
    /// reading that would have spent it has already been and gone, so without
    /// this the row waits for a notification that will never come again.
    /// @witness VaultIntegrity.aTeardownThatTookTheStoreStopsTheRestore
    /// @witness ActivationSeam.aTeardownHoldingTheStoreTakesNoHandOff
    func releaseStoreAfterUninstall() {
        refreshSuspended = false
        activateWaitingTunnelIfNeeded()
    }

    /// @witness VaultIntegrity.theExtensionsComingBackDoesNotLowerTheTeardownsBar
    func releaseAbandonedStoreLatch() {
        guard refreshSuspended else { return }
        NSLog("[uninstall] the refresh latch outlived its teardown — released on the extensions' return")
        refreshSuspended = false
        scheduleRefresh()
    }

    private func entryGoesFirst(for tunnel: TunnelContainer) async throws -> Bool {
        switch await vault.read(id: tunnel.id, attempts: 3) {
        case .config, .missing:
            return true
        case .undecodable:
            NSLog("[remove] \(tunnel.id): the payload does not decode — its entry is the only anchor, so the payload goes first")
            return false
        case .unreachable:
            throw TunnelManagementError.vaultUnavailable
        }
    }

    func removableEntryIds() async -> Set<UUID> {
        var ids = Set<UUID>()
        for tunnel in tunnels {
            if case .config = await vault.read(id: tunnel.id) {
                ids.insert(tunnel.id)
            }
        }
        return ids
    }

    /// @witness VaultIntegrity.theUninstallRemovalTakesOnlyTheClassifiedEntries
    /// @witness VaultIntegrity.theUninstallsRemovalIsNotUndoneByTheRestore
    /// @witness VaultIntegrity.aTeardownThatTakesNoEntryLeavesTheRestoreAlone
    func removeEntriesForUninstall(_ removableIds: Set<UUID>) async {
        guard let providers = try? await providerFactory.loadAllFromPreferences() else {
            NSLog("[uninstall] entry removal skipped — the system list did not load")
            return
        }
        var unclassified = 0
        var removable: [(id: UUID, provider: TunnelProviding)] = []
        for provider in providers {
            guard let id = provider.tunnelIdentity?.id else { continue }
            if removableIds.contains(id) {
                removable.append((id, provider))
            } else {
                unclassified += 1
            }
        }

        let barWasAlreadyUp = restoreBarredByTeardown
        if !removable.isEmpty {
            restoreBarredByTeardown = true
            NSLog("[uninstall] the restore is barred from here on: \(removable.count) entry(ies) are being taken while their payloads stay in the vault")
        }

        var taken = 0
        for (id, provider) in removable {
            do {
                try await provider.removePreferences()
                taken += 1
            } catch {
                NSLog("[uninstall] entry removal failed for \(provider.localizedDescription ?? id.uuidString): \(error.localizedDescription)")
            }
        }

        if taken == 0, !barWasAlreadyUp, restoreBarredByTeardown {
            restoreBarredByTeardown = false
            NSLog("[uninstall] every removal was refused, so no entry was taken and the restore is not barred after all")
        }
        if unclassified > 0 {
            NSLog("[uninstall] \(unclassified) identified entry(ies) were outside the removable set and stay in the system store — another user's, or ours with a payload that does not decode")
        }
    }

    static func noSystemDetail(_ description: String) -> NSError {
        NSError(
            domain: "PhantomWG",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    // MARK: - Status Observation

    private func startObservingTunnelStatuses() {
        statusObservationToken = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let tunnel = self.tunnels.first(where: { $0.tunnelProvider.matchesNotification(notification) })
                else { return }
                self.handleStatusChange(for: tunnel)
            }
        }
    }

    /// @witness ActivationSeam.anInvalidOccupantDoesNotHandOnTheQueue
    /// @witness ActivationSeam.aFlickerBackToInvalidIsStillNotAnAnswer
    /// @witness ActivationSeam.aTransientDoesNotRepaintAHeldRow
    private func releaseGroundingCeiling(for tunnel: TunnelContainer, on systemStatus: NEVPNStatus) {
        guard systemStatus.isTerminalAnswer else { return }
        tunnel.standDownCeiling()
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func handleStatusChange(for tunnel: TunnelContainer) {
        let systemStatus = tunnel.tunnelProvider.connectionStatus
        releaseGroundingCeiling(for: tunnel, on: systemStatus)

        if tunnel.isAttemptingActivation {
            switch systemStatus {
            case .connected:
                tunnel.isAttemptingActivation = false
                tunnel.activationTask?.cancel()
                tunnel.activationTask = nil
                tunnel.status = .active
                tunnel.clearErrorOnRise()

            case .disconnected:
                let droppedMidActivation = tunnel.status == .activating || tunnel.status == .reasserting
                tunnel.isAttemptingActivation = false
                tunnel.activationTask?.cancel()
                tunnel.activationTask = nil
                tunnel.status = .inactive

                if tunnel.lastActivationError == nil {
                    let attemptId = tunnel.activationAttemptId
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .heldByForeign = await self.foreignSlotVerdict() {
                            if case .barred = await self.guardedStandDown(tunnel, context: "after a proven foreign holder") {
                                return
                            }
                            guard tunnel.activationAttemptId == attemptId,
                                  tunnel.lastActivationError == nil,
                                  tunnel.status == .inactive else { return }
                            tunnel.lastActivationError = .foreignSlotHolder
                            return
                        }
                        let fetched: NSError?? = await self.bounded(3) {
                            (await tunnel.tunnelProvider.fetchLastDisconnectError()).map { $0 as NSError }
                        }
                        guard tunnel.activationAttemptId == attemptId,
                              tunnel.lastActivationError == nil,
                              tunnel.status == .inactive,
                              self.tunnels.contains(where: { $0 === tunnel }) else { return }
                        if let record = fetched.flatMap({ $0 }) {
                            tunnel.lastActivationError = .failedWhileActivating(systemError: record)
                            return
                        }
                        let unanswered = fetched == nil
                        let standIn = Self.noSystemDetail(LocalizationManager.shared.t(
                            unanswered ? "error_detail_timeout" : "error_detail_session_ended"))
                        if droppedMidActivation, !tunnel.respawnReviveConsumed {
                            tunnel.respawnReviveConsumed = true
                            tunnel.respawnReviveTask = Task { @MainActor [weak self] in
                                try? await Task.sleep(for: .seconds(1))
                                guard let self, !Task.isCancelled else { return }
                                guard tunnel.activationAttemptId == attemptId,
                                      tunnel.status == .inactive,
                                      tunnel.lastActivationError == nil,
                                      !self.removingIds.contains(tunnel.id),
                                      self.tunnels.contains(where: { $0 === tunnel }),
                                      !self.tunnels.contains(where: { $0.id != tunnel.id && $0.status != .inactive })
                                else {
                                    if tunnel.activationAttemptId == attemptId,
                                       tunnel.lastActivationError == nil,
                                       tunnel.status == .inactive {
                                        tunnel.lastActivationError = .failedWhileActivating(systemError: standIn)
                                    }
                                    return
                                }
                                NSLog("[activation] mid-activation drop with \(unanswered ? "no answer from the system" : "no system record") — spending the one revive on \(tunnel.name)")
                                self.beginActivation(of: tunnel)
                            }
                            return
                        }
                        tunnel.lastActivationError = .failedWhileActivating(systemError: standIn)
                    }
                }

                activateWaitingTunnelIfNeeded()

            case .connecting:
                tunnel.status = .activating

            case .disconnecting:
                tunnel.status = .deactivating

            case .reasserting:
                tunnel.status = .reasserting
                tunnel.clearErrorOnRise()

            default:
                break
            }
        } else {
            if systemStatus == .invalid,
               tunnel.status == .deactivating || tunnel.stopIsWaitingOnItsRule,
               tunnel.groundingCeilingTask == nil {
                tunnel.status = .deactivating
                armGroundingCeiling(for: tunnel)
                return
            }
            tunnel.refreshStatus()

            if tunnel.status == .inactive {
                activateWaitingTunnelIfNeeded()
            }
        }
    }

    // MARK: - Configuration Observation, Reload & Ingest

    private func startObservingTunnelConfigurations() {
        configObservationToken = NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
    }

    private func startObservingForeground() {
        foregroundObservationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        guard !refreshSuspended else { return }
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    private func reload() async {
        guard let providers = try? await providerFactory.loadAllFromPreferences() else { return }
        await ingest(providers)
        guard !refreshSuspended else { return }
        await reconcileFromVault()
        guard !refreshSuspended else { return }
        activateWaitingTunnelIfNeeded()
    }

    #if DEBUG
    /// @witness ActivationSeam
    /// @witness VaultIntegrity
    func refresh() async {
        await reload()
    }

    /// @witness VaultIntegrity
    func prune() async {
        guard let providers = try? await providerFactory.loadAllFromPreferences() else { return }
        await ingest(providers)
        if let waiting = waitingTunnel, !tunnels.contains(where: { $0 === waiting }) {
            waitingTunnel = nil
        }
    }
    #endif

    private func ingest(_ providers: [TunnelProviding]) async {
        let mine = await ownedProviders(among: providers)

        var newTunnels: [TunnelContainer] = []
        for provider in mine {
            if let existing = tunnels.first(where: { $0.id == provider.tunnelIdentity?.id }) {
                existing.name = provider.localizedDescription ?? ""
                existing.refreshStatus()
                newTunnels.append(existing)
            } else {
                newTunnels.append(TunnelContainer(tunnel: provider))
            }
        }
        tunnels = Self.sortedByCreatedAt(newTunnels)
    }

    private func ownedProviders(among providers: [TunnelProviding]) async -> [TunnelProviding] {
        guard case .configs(let mine) = await vault.readAll() else {
            let cached = Set(tunnels.map(\.id))
            let kept = providers.filter { provider in
                provider.tunnelIdentity.map { cached.contains($0.id) } ?? false
            }
            if kept.count != providers.count {
                NSLog("[vault] ingest uid \(currentUser): kept \(kept.count)/\(providers.count) via cache (vault unreachable), \(providers.count - kept.count) unverified held back")
            }
            return kept
        }

        let decodedIDs = Set(mine.map(\.id))
        var kept: [TunnelProviding] = []
        var foreign = 0
        var custody = 0
        var unverified = 0
        var unattributed = 0
        var vaultWentDark = false
        for provider in providers {
            guard let id = provider.tunnelIdentity?.id else {
                unattributed += 1
                continue
            }
            if decodedIDs.contains(id) {
                kept.append(provider)
                continue
            }
            if vaultWentDark {
                if tunnels.contains(where: { $0.id == id }) { kept.append(provider) } else { unverified += 1 }
                continue
            }
            switch await vault.read(id: id) {
            case .config:
                kept.append(provider)
            case .undecodable:
                custody += 1
                kept.append(provider)
            case .missing:
                foreign += 1
            case .unreachable:
                vaultWentDark = true
                if tunnels.contains(where: { $0.id == id }) { kept.append(provider) } else { unverified += 1 }
            }
        }
        if kept.count != providers.count || custody > 0 {
            NSLog("[vault] ingest uid \(currentUser): kept \(kept.count)/\(providers.count) via vault — \(foreign) other users', \(custody) kept for custody (payload present, not decodable), \(unverified) unverified in a dark window, \(unattributed) without identity")
        }
        return kept
    }

    func foreignSlotVerdict(within seconds: Double? = nil) async -> SlotVerdict {
        guard let seconds else { return await computeForeignSlotVerdict() }
        return await bounded(seconds) { await self.computeForeignSlotVerdict() } ?? .free
    }

    private func computeForeignSlotVerdict() async -> SlotVerdict {
        guard let providers = try? await providerFactory.loadAllFromPreferences(),
              case .configs(let mine) = await vault.readAll() else { return .free }
        return await SlotClassifier.classify(
            providers: providers,
            ownedIDs: Set(mine.map(\.id))
        ) { await self.vault.read(id: $0) }
    }

    func bounded<T: Sendable>(
        _ seconds: Double,
        _ producer: @escaping @MainActor () async -> T
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let resume = SingleResume(continuation)
            Task { @MainActor in resume.finish(await producer()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                resume.finish(nil)
            }
        }
    }
}
