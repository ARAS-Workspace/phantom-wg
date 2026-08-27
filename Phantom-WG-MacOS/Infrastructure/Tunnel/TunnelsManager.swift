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

    /// An unanswered disarm save on the ledger makes each rung wait up to
    /// disarmPatience before arming, so the belt may cut the ladder short of
    /// retryLimitReached — in the safe direction; the ceiling leaves that
    /// wait uncounted on purpose.
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
            // The uniqueness reading at the top is stale by here: the vault
            // writes above span suspensions a concurrent add can cross with
            // the same name. Re-read before the entry is created; the catch
            // below rolls the stored payload back.
            if tunnels.contains(where: {
                $0.id != config.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                throw TunnelManagementError.tunnelAlreadyExistsWithThatName
            }
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
            guard !refreshSuspended else { return 0 }
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
        for snapshot in payloads where !attempted.contains(snapshot.id) {
            guard !refreshSuspended else {
                NSLog("[vault] realign stopped at \(snapshot.id): a teardown took the store")
                return
            }
            guard let tunnel = tunnels.first(where: { $0.id == snapshot.id }),
                  let projected = tunnel.tunnelProvider.tunnelIdentity,
                  projected.name != snapshot.name || projected.isGhost != snapshot.isGhostMode
            else { continue }

            // The snapshot only nominates. The write below follows the mint
            // path's discipline: the payload is proven fresh first — an edit
            // can move it while this reconcile's awaits run, and a t0 copy
            // would drag a fresh projection back to a stale name.
            let config: TunnelConfig
            switch await provePayload(snapshot) {
            case .mint(let fresh):
                config = fresh
            case .skip:
                continue
            case .dark:
                NSLog("[vault] realign stopped at \(snapshot.id): the vault went dark — the remaining projections keep their drift for whichever trigger reconciles next")
                return
            }
            guard !refreshSuspended else {
                NSLog("[vault] realign stopped at \(snapshot.id): a teardown took the store while the payload was being proven")
                return
            }
            guard let freshProjected = tunnel.tunnelProvider.tunnelIdentity,
                  freshProjected.name != config.name || freshProjected.isGhost != config.isGhostMode
            else { continue }

            guard tunnel.status == .inactive || tunnel.status == .unknown else {
                NSLog("[vault] reconcile skipped realigning \(config.id): the row shows \(tunnel.status) — only an inactive or unknown row takes this write")
                continue
            }

            await writeRealignedProjection(config, onto: tunnel)
        }
    }

    private func writeRealignedProjection(_ config: TunnelConfig, onto tunnel: TunnelContainer) async {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tunnels.contains(where: {
            $0.id != config.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            NSLog("[vault] reconcile skipped realigning \(config.id): a tunnel named '\(name)' already exists")
            return
        }

        guard mayWriteStore(tunnel) else {
            NSLog("[vault] reconcile skipped realigning \(config.id): the row is no longer this manager's to write")
            return
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
        // The disarm-save wait remove() runs is run here too: a save still on
        // the ledger is waited out — under the same ceiling — before this edit
        // writes the vault or the store. (remove() additionally waits out rung
        // and parked-stop tasks — the wider set a removal must outlive.) Once
        // the edit moves on, the order between that save's landing and
        // savePreferences below is not this app's to control; if the bound
        // passes, the edit proceeds as today.
        let disarmSaveLanded = await Self.awaitLingeringDisarmSave(on: tunnel.tunnelProvider, within: 20)
        if !disarmSaveLanded {
            NSLog("[modify] the disarm save on \(tunnel.name) was still running at the edit's ceiling — the edit proceeds with the save in flight")
        }
        // The wait spans a suspension a removal can cross: the bar above is
        // re-read — with list membership, since a finished removal has already
        // left removingIds — before anything is written.
        guard mayWriteStore(tunnel) else {
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

        // The readings above are stale by here: the purge and store span
        // suspensions a concurrent add, edit, or removal can cross. Both bars
        // are re-read before the store is written. On a refusal the vault
        // keeps the new payload — the drift the TunnelEdit witness declares,
        // and realign's own name bar refuses the projection write while a
        // clash stands.
        guard mayWriteStore(tunnel) else {
            throw TunnelManagementError.vpnSystemErrorOnModifyTunnel(
                systemError: Self.noSystemDetail(LocalizationManager.shared.t("error_detail_session_ended")))
        }
        if tunnels.contains(where: {
            $0.id != tunnel.id
                && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            throw TunnelManagementError.tunnelAlreadyExistsWithThatName
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
        try await awaitRungsSettledForRemoval(of: tunnel)
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

        switch await Self.standDownRecovery(on: tunnel.tunnelProvider) {
        case .done:
            break
        case .refused(let disarmError):
            NSLog("[remove] disarm save refused on \(tunnel.name) — the flag here holds this manager's write (disarmed); the store keeps whatever the refusal left until the next load: \(disarmError.localizedDescription)")
        case .unanswered:
            NSLog("[remove] disarm save on \(tunnel.name) has not answered — the removal waits it out below before touching the system store")
        }

        // A disarm save still on the ledger is waited out — under the same
        // ceiling as the rung wait above — before the entry is removed: once
        // the removal moves on, the order between that save's landing and
        // removePreferences is not this app's to control.
        let disarmSaveLanded = await Self.awaitLingeringDisarmSave(on: tunnel.tunnelProvider, within: 20)
        if !disarmSaveLanded {
            NSLog("[remove] the disarm save on \(tunnel.name) was still running at the removal's ceiling — the removal proceeds with the save in flight")
        }

        do {
            try await tunnel.tunnelProvider.removePreferences()
        } catch {
            if entryFirst {
                tunnel.refreshStatus()
            } else {
                // The undecodable payload is already deleted and its bytes
                // cannot be written back (only a decoded config can be
                // stored). The entry this removal failed on is now unbacked:
                // the next ingest reads its id as .missing and drops the row.
                NSLog("[remove] \(tunnel.name): the entry removal failed AFTER its undecodable payload was deleted — the entry is unbacked, and the next ingest will read it as another user's and drop the row; retrying the removal before that read still takes the entry, afterwards only System Settings does")
            }
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

    /// The removal's entry wait: an activation rung or a parked disarm task
    /// still running would write behind the removal — both are waited out
    /// under the removal's ceiling before anything is torn down.
    private func awaitRungsSettledForRemoval(of tunnel: TunnelContainer) async throws {
        let rungSettled: Bool? = await bounded(20) {
            await tunnel.activationRungTask?.value
            await tunnel.pendingDisarmTask?.value
            return true
        }
        guard rungSettled == true else {
            throw TunnelManagementError.vpnSystemErrorOnRemoveTunnel(
                systemError: Self.noSystemDetail(LocalizationManager.shared.t("error_detail_timeout")))
        }
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

    /// Giving the store back does nothing but give it back. Raising a session
    /// from here would run in a `defer` that fires on the throwing path too, on
    /// a row whose configuration the uninstall has already deleted — and
    /// `startActivation` would write that configuration straight back. The
    /// questions the bar parked are closed where they are asked instead: the
    /// sweep grounds the rows it takes, and `beginActivation` takes no slot
    /// while the latch is up.
    /// @witness VaultIntegrity.aTeardownThatTookTheStoreStopsTheRestore
    func releaseStoreAfterUninstall() {
        refreshSuspended = false
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
            NSLog("[remove] \(tunnel.id): the payload does not decode — its entry is the only anchor, so the payload goes first; should the entry removal then fail, the entry is left unbacked and the next ingest drops the row")
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
            await awaitDisarmSaveBeforeSweepRemoval(of: id, label: provider.localizedDescription ?? id.uuidString)
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
            NSLog("[uninstall] \(unclassified) identified entry(ies) were outside the removable set and stay in the system store — another user's, ours with a payload that does not decode, or ours left unclassified because the vault did not answer while the removable set was taken")
        }
    }

    /// The disarm-save wait remove() runs, run for the sweep on the LISTED
    /// row's provider: the ledger is keyed by provider object, and the
    /// freshly loaded copy the sweep iterates does not carry the listed
    /// row's lingering save. A row the list no longer holds has no
    /// addressable ledger entry to wait on.
    private func awaitDisarmSaveBeforeSweepRemoval(of id: UUID, label: String) async {
        guard let listed = tunnels.first(where: { $0.id == id })?.tunnelProvider else {
            NSLog("[uninstall] no listed row for \(id) — the sweep has no addressable ledger entry to wait on before its removal")
            return
        }
        if !(await Self.awaitLingeringDisarmSave(on: listed, within: 20)) {
            NSLog("[uninstall] the disarm save on \(label) was still running at the sweep's ceiling — the removal proceeds with the save in flight")
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

    // swiftlint:disable:next function_body_length
    private func handleStatusChange(for tunnel: TunnelContainer) {
        let systemStatus = tunnel.tunnelProvider.connectionStatus

        if tunnel.isAttemptingActivation {
            switch systemStatus {
            case .connected:
                tunnel.isAttemptingActivation = false
                tunnel.activationTask?.cancel()
                tunnel.activationTask = nil
                tunnel.status = .active
                tunnel.clearErrorOnRise()

            case .disconnected:
                tunnel.isAttemptingActivation = false
                tunnel.activationTask?.cancel()
                tunnel.activationTask = nil
                tunnel.status = .inactive

                if tunnel.lastActivationError == nil {
                    let attemptId = tunnel.activationAttemptId
                    // The verdict guards below admit .unknown alongside
                    // .inactive: the awaits in this task can span a repaint
                    // (a live .invalid lands as .unknown), and neither
                    // painted reading carries a session claim — the same
                    // pair the else-door of this handler admits.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .heldByForeign = await self.foreignSlotVerdict(within: self.preflightBudget) {
                            // The guards run BEFORE anything is written and
                            // the sentence lands BEFORE the stand-down — the
                            // siblings' order (rung-0 pre-flight, start-catch):
                            // a stale verdict does not lower a fresh press's
                            // arm on the user's behalf, and no write of this
                            // task lands behind its own suspension. The
                            // stand-down guards itself: guardedStandDown
                            // re-reads mayWriteStore (list membership included)
                            // across its own suspension.
                            guard tunnel.activationAttemptId == attemptId,
                                  tunnel.lastActivationError == nil,
                                  tunnel.status == .inactive || tunnel.status == .unknown,
                                  self.tunnels.contains(where: { $0 === tunnel }) else { return }
                            tunnel.lastActivationError = .foreignSlotHolder
                            await self.guardedStandDown(tunnel, context: "after a proven foreign holder")
                            return
                        }
                        let fetched: NSError?? = await self.bounded(3) {
                            (await tunnel.tunnelProvider.fetchLastDisconnectError()).map { $0 as NSError }
                        }
                        guard tunnel.activationAttemptId == attemptId,
                              tunnel.lastActivationError == nil,
                              tunnel.status == .inactive || tunnel.status == .unknown,
                              self.tunnels.contains(where: { $0 === tunnel }) else { return }
                        if let record = fetched.flatMap({ $0 }) {
                            tunnel.lastActivationError = .failedWhileActivating(systemError: record)
                            return
                        }
                        let unanswered = fetched == nil
                        let standIn = Self.noSystemDetail(LocalizationManager.shared.t(
                            unanswered ? "error_detail_timeout" : "error_detail_session_ended"))
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
            tunnel.refreshStatus()

            if tunnel.status == .inactive || tunnel.status == .unknown {
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
            NSLog("[vault] ingest uid \(currentUser): kept \(kept.count)/\(providers.count) via vault — \(foreign) other users', \(custody) kept for custody (payload present, not decodable), \(unverified) unverified in a dark window, \(unattributed) without identity\(vaultWentDark ? "; rows listed before the dark window were kept by the cache, not the vault" : "")")
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
