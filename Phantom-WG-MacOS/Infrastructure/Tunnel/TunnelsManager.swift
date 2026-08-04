import Foundation
import AppKit
import NetworkExtension

@Observable
@MainActor
class TunnelsManager {

    var tunnels: [TunnelContainer] = []

    @ObservationIgnored private let providerFactory: TunnelProviderFactory
    @ObservationIgnored let vault: TunnelVaultClient
    @ObservationIgnored private var statusObservationToken: AnyObject?
    @ObservationIgnored private var configObservationToken: AnyObject?
    @ObservationIgnored private var foregroundObservationToken: AnyObject?

    /// Serializes reconcile passes. Creating an entry makes the system
    /// broadcast a configuration change, which reloads and reconciles
    /// again — the flag keeps those from interleaving and creating the
    /// same tunnel twice.
    @ObservationIgnored private var isReconciling = false
    @ObservationIgnored var waitingTunnel: TunnelContainer?

    // Activation retry pacing (consumed by TunnelsManager+Activation)
    let retryInterval: TimeInterval = 5.0
    let maxRetries: Int = 8

    // MARK: - Factory

    static func create(vault: TunnelVaultClient) async throws -> TunnelsManager {
        let factory = RealTunnelProviderFactory()
        let providers = try await factory.loadAllFromPreferences()
        return TunnelsManager(tunnelProviders: providers, providerFactory: factory, vault: vault)
    }

    init(
        tunnelProviders: [TunnelProviding],
        providerFactory: TunnelProviderFactory = RealTunnelProviderFactory(),
        vault: TunnelVaultClient
    ) {
        self.providerFactory = providerFactory
        self.vault = vault
        tunnels = Self.sortedByCreatedAt(tunnelProviders.map { TunnelContainer(tunnel: $0) })
        startObservingTunnelStatuses()
        startObservingTunnelConfigurations()
        startObservingForeground()
    }

    /// Newest first — tunnels without a persisted `createdAt` fall back
    /// to `.distantPast` so they sort below freshly-created ones.
    static func sortedByCreatedAt(_ list: [TunnelContainer]) -> [TunnelContainer] {
        list.sorted {
            let lhs = $0.identity?.createdAt ?? .distantPast
            let rhs = $1.identity?.createdAt ?? .distantPast
            return lhs > rhs
        }
    }

    deinit {
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

    func add(config: TunnelConfig) async throws -> TunnelContainer {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw TunnelManagementError.tunnelInvalidName
        }
        if tunnels.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw TunnelManagementError.tunnelAlreadyExistsWithThatName
        }

        await purgeVaultDuplicates(of: config)

        // Secrets first. A tunnel entry whose vault payload is missing
        // cannot start, so the vault write gates the whole operation —
        // and a failure here leaves the system exactly as it was.
        guard await vault.store(config) else {
            throw TunnelManagementError.vaultUnavailable
        }

        do {
            return try await createEntry(for: config)
        } catch {
            // Roll the vault back so a failed add leaves no orphaned
            // secrets behind.
            await vault.delete(id: config.id)
            throw error
        }
    }

    // MARK: - Reconcile

    /// Makes the system store agree with the vault, in both
    /// directions, because the vault is the source of truth: it holds
    /// each tunnel's whole configuration and outlives what the system
    /// keeps — macOS drops a tunnel's NetworkExtension configuration
    /// when its provider extension is uninstalled.
    ///
    /// A payload with no system entry is recreated, unprompted: the
    /// user has nothing to decide, the tunnel exists and the system
    /// simply forgot it. An entry with no payload is removed just as
    /// quietly — it cannot start, and telling the operator to repair
    /// something that is by definition unrepairable is worse than
    /// clearing it away. Nothing is destroyed by that removal: the
    /// entry pointed at a payload that is already gone.
    ///
    /// Both directions rest on the vault having actually answered. A
    /// vault that cannot be reached teaches us nothing, and acting on
    /// that silence would delete every tunnel on the machine, so the
    /// pass simply does not run.
    @discardableResult
    func reconcileFromVault() async -> Int {
        // Idempotent by construction — it only creates entries the
        // vault backs and the system lacks, and only removes entries
        // the vault does not back, so a second pass over an unchanged
        // world does nothing. The flag is about overlap, not
        // repetition: a pass in flight must finish before the next one
        // reads the list it is still adding to.
        guard !isReconciling else { return 0 }
        isReconciling = true
        defer { isReconciling = false }

        guard case .configs(let payloads) = await vault.readAll() else {
            NSLog("[vault] reconcile skipped — the vault did not answer")
            return 0
        }

        await dropEntriesWithoutPayload(vaultIds: Set(payloads.map(\.id)))

        let known = Set(tunnels.map(\.id))
        let missing = payloads
            .filter { !known.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }

        var restored = 0
        for config in missing {
            // Names stay unique here too. Import and edit both refuse
            // a duplicate name, so reconcile must not be the one path
            // that manufactures one — a second tunnel with the same
            // name is indistinguishable to the operator and collides
            // in the name-keyed accessibility identifiers. The
            // payload is left in the vault rather than deleted:
            // renaming the tunnel that holds the name frees it, and
            // the next launch brings this one back.
            let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tunnels.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                NSLog("[vault] reconcile skipped \(config.id): a tunnel named '\(name)' already exists")
                continue
            }

            do {
                _ = try await createEntry(for: config)
                restored += 1
            } catch {
                // The payload stays put; the next launch tries again.
                NSLog("[vault] reconcile failed for \(config.id): \(error.localizedDescription)")
            }
        }

        if restored > 0 {
            NSLog("[vault] reconcile restored \(restored) tunnel(s) the system had lost")
        }
        return restored
    }

    /// Removes system entries the vault does not back. Such an entry
    /// is a pointer to nothing: it cannot start, and no repair exists
    /// for it, so it is cleared instead of being shown as a fault.
    ///
    /// Two guards keep this from ever removing something real. A
    /// tunnel that is not idle is left alone — the running session
    /// owns its configuration and this is no moment to pull the entry
    /// out from under it. And every candidate is confirmed with its
    /// own read: the bulk answer is a snapshot, and a tunnel imported
    /// while this pass was in flight would look absent in it.
    private func dropEntriesWithoutPayload(vaultIds: Set<UUID>) async {
        for tunnel in tunnels where !vaultIds.contains(tunnel.id) {
            guard tunnel.status == .inactive else { continue }
            guard case .missing = await vault.read(id: tunnel.id) else { continue }

            do {
                try await tunnel.tunnelProvider.removePreferences()
                tunnels.removeAll { $0.id == tunnel.id }
                NSLog("[vault] dropped system entry \(tunnel.id) — the vault holds no payload for it")
            } catch {
                NSLog("[vault] could not drop system entry \(tunnel.id): \(error.localizedDescription)")
            }
        }
    }

    /// Drops any *other* payload that already claims this tunnel's
    /// name. Names are unique among listed tunnels, but a payload can
    /// outlive its entry — and one of those, holding a name the user
    /// is now reusing, would otherwise sit in the vault forever:
    /// reconcile refuses to restore it (the name is taken) and nothing
    /// else ever looks at it. Writing the name is the moment the user
    /// says which tunnel owns it, so that is where the old claim goes.
    private func purgeVaultDuplicates(of config: TunnelConfig) async {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard case .configs(let payloads) = await vault.readAll() else { return }

        for other in payloads where other.id != config.id {
            let otherName = other.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard otherName.caseInsensitiveCompare(name) == .orderedSame else { continue }
            await vault.delete(id: other.id)
            NSLog("[vault] dropped stale payload \(other.id) that claimed the name '\(name)'")
        }
    }

    /// Creates and persists the system entry for a config, then adds
    /// it to the list. Shared by `add` and `restore`.
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

        let tunnel = TunnelContainer(tunnel: provider)
        tunnels.append(tunnel)
        tunnels = Self.sortedByCreatedAt(tunnels)
        return tunnel
    }

    func modify(tunnel: TunnelContainer, with config: TunnelConfig) async throws {
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

        await purgeVaultDuplicates(of: config)

        // Same ordering as `add`. If the preference save fails after
        // this, the vault holds the edit while the identity projection
        // stays stale — the tunnel still starts from the new payload,
        // and the next successful edit realigns the projection.
        guard await vault.store(config) else {
            throw TunnelManagementError.vaultUnavailable
        }

        tunnel.tunnelProvider.localizedDescription = name
        tunnel.tunnelProvider.isEnabled = true
        tunnel.tunnelProvider.configure(with: config.identity)

        do {
            try await tunnel.tunnelProvider.savePreferences()
            try await tunnel.tunnelProvider.loadPreferences()
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnModifyTunnel(systemError: error)
        }

        tunnel.name = name
    }

    func remove(tunnel: TunnelContainer) async throws {
        // The payload goes first, and its failure stops everything.
        //
        // Removing the system entry first looks tidier but loses the
        // race with our own machinery: that removal makes the system
        // broadcast a configuration change, which reconciles, which
        // finds a payload with no entry and dutifully puts the entry
        // back. Taking the truth away first means every later pass
        // agrees the tunnel is gone. And if the vault cannot be
        // reached, refusing outright leaves the tunnel whole rather
        // than half-deleted.
        guard await vault.delete(id: tunnel.id) else {
            throw TunnelManagementError.vaultUnavailable
        }

        do {
            try await tunnel.tunnelProvider.removePreferences()
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnRemoveTunnel(systemError: error)
        }

        if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            tunnels.remove(at: index)
        }

        if waitingTunnel?.id == tunnel.id {
            waitingTunnel = nil
        }
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

    private func handleStatusChange(for tunnel: TunnelContainer) {
        let systemStatus = tunnel.tunnelProvider.connectionStatus

        if tunnel.isAttemptingActivation {
            switch systemStatus {
            case .connected:
                tunnel.isAttemptingActivation = false
                tunnel.activationTask?.cancel()
                tunnel.activationTask = nil
                tunnel.status = .active

            case .disconnected:
                tunnel.isAttemptingActivation = false
                tunnel.activationTask?.cancel()
                tunnel.activationTask = nil
                tunnel.status = .inactive

                if tunnel.lastActivationError == nil {
                    tunnel.lastActivationError = .failedWhileActivating(
                        systemError: NSError(domain: NEVPNErrorDomain, code: 0))
                }

            case .connecting:
                tunnel.status = .activating

            case .disconnecting:
                tunnel.status = .deactivating

            case .reasserting:
                tunnel.status = .reasserting

            default:
                break
            }
        } else {
            let newStatus = TunnelStatus(from: systemStatus)
            tunnel.status = newStatus

            if newStatus == .inactive {
                let onDeactivated = tunnel.onDeactivated
                tunnel.onDeactivated = nil
                onDeactivated?(tunnel)

                activateWaitingTunnelIfNeeded()
            }
        }

        let isActive = tunnels.contains { $0.status == .active }
        NotificationCenter.default.post(
            name: NSNotification.Name("PhantomTunnelStatusChanged"),
            object: nil,
            userInfo: ["isActive": isActive]
        )
    }

    // MARK: - Configuration Observation

    /// The system broadcasts this whenever any VPN configuration
    /// changes — including one deleted from System Settings while the
    /// app is running. Reloading refreshes the list; reconciling then
    /// puts back anything the vault still holds, which is what makes
    /// an out-of-band deletion self-healing.
    private func startObservingTunnelConfigurations() {
        configObservationToken = NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.reload()
            }
        }
    }

    /// Coming back to the foreground is the catch-all trigger: it
    /// covers the launch where the extension was not answering yet,
    /// and any change that happened while the app was in the
    /// background without a notification reaching it.
    private func startObservingForeground() {
        foregroundObservationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.reconcileFromVault()
            }
        }
    }

    private func reload() async {
        guard let providers = try? await providerFactory.loadAllFromPreferences() else { return }

        var newTunnels: [TunnelContainer] = []

        for provider in providers {
            if let existing = tunnels.first(where: { $0.tunnelProvider.isEqual(to: provider) }) {
                existing.name = provider.localizedDescription ?? ""
                existing.refreshStatus()
                newTunnels.append(existing)
            } else {
                newTunnels.append(TunnelContainer(tunnel: provider))
            }
        }

        tunnels = Self.sortedByCreatedAt(newTunnels)

        // The list now mirrors the system store; put back whatever the
        // vault says should be in it.
        await reconcileFromVault()
    }
}
