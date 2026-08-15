import Foundation
import AppKit
import NetworkExtension

// Sealed at file size: hardening package after hardening package grew
// this manager along its real seams (activation already lives in its
// own extension), and the next split belongs to those seams when the
// cleanup ledger calls for it — not to a counter. The thresholds stay
// live for every other file in the product; the type carries its own
// seal at the class.
// swiftlint:disable file_length

/// Source of truth for the tunnel list. Owns the pairing between the
/// system's NetworkExtension preferences (identity-only projections)
/// and the extension's TunnelVault (the payloads): `ingest` scopes the
/// system-wide list to this user's own entries, `reconcileFromVault`
/// restores vault payloads the system lost and realigns drifted
/// projections (purely additive — under the ownership boundary an
/// unbacked entry cannot be told apart from another local user's) —
/// `creatingIds` keeps a pass from minting an entry for a tunnel
/// mid-import, and the debounced refresh coalesces the system's
/// change-notification bursts into single reload+reconcile passes.
/// Activation lives in `TunnelsManager+Activation`: one active tunnel
/// at a time — a newly toggled tunnel waits out the previous one's
/// deactivation before it starts. Every activation that passes the
/// foreign-slot pre-flight silently arms the recovery rule (one
/// connect-on-any-network on-demand rule): an activated tunnel is one
/// the user wants back, so the system revives it across reboots, app
/// termination, and network loss. The rule stands down on
/// deactivation, when activating one tunnel disarms every other
/// tunnel's, and whenever another local user's session is proven to
/// hold the system's one VPN slot (the collision belts and the
/// connection gate's engage sweep) — an armed rule against an
/// occupied slot only feeds the cross-user fight.
@Observable
@MainActor
// swiftlint:disable:next type_body_length
class TunnelsManager {

    var tunnels: [TunnelContainer] = []

    @ObservationIgnored private let providerFactory: TunnelProviderFactory
    @ObservationIgnored let vault: TunnelVaultClient

    /// The uid this app instance runs as, read from the system once at
    /// construction. The system extension and its NE configurations are
    /// system-wide, so `loadAllFromPreferences` hands back every local
    /// user's configs; the vault, by contrast, is owner-scoped to this
    /// same uid — and that owner-scoped `readAll` is what the ingest
    /// boundary actually filters on. This value is the matching
    /// identity, surfaced in the ownership-pass diagnostic; overridable
    /// at construction so the multi-user paths could be driven as any
    /// user.
    @ObservationIgnored let currentUser: uid_t
    @ObservationIgnored private var statusObservationToken: AnyObject?
    @ObservationIgnored private var configObservationToken: AnyObject?
    @ObservationIgnored private var foregroundObservationToken: AnyObject?

    /// Serializes reconcile passes. Creating an entry makes the system
    /// broadcast a configuration change, which reloads and reconciles
    /// again — the flag keeps those from interleaving and creating the
    /// same tunnel twice.
    @ObservationIgnored private var isReconciling = false

    /// Ids whose system entry is being written right now. An add puts
    /// the payload in the vault before `savePreferences` lands the
    /// entry, and a reconcile pass squeezing into that gap — off a
    /// change notification whose reload still read the old, emptier
    /// list — sees "payload with no entry" and mints a second one.
    /// Field-measured on a first import; this set forbids it.
    @ObservationIgnored private var creatingIds: Set<UUID> = []

    /// Coalesces the refresh triggers. The system announces one change
    /// as a burst of notifications more often than not, and a
    /// foreground return can land on top of them — while every pass
    /// costs a full vault read that wakes the extension. One trailing
    /// pass serves the whole burst; `isReconciling` guards overlap,
    /// this guards repetition.
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    /// Raised for the uninstall window. Entry removals fire
    /// configuration-change bursts, and a reload pass sampling the
    /// vault mid-teardown would resurrect what the flow is removing
    /// (reconcile restores any answered payload missing its entry).
    /// The teardown owns the store during this window; refreshes
    /// stand down instead of racing it. Lowered again only at the two
    /// provable returns to list-world — a failed teardown, or
    /// extensions reactivated from the gate (`resumeRefresh`) — so a
    /// process that comes back does not live on with every self-heal
    /// silently dead.
    @ObservationIgnored private var refreshSuspended = false

    @ObservationIgnored var waitingTunnel: TunnelContainer?

    // Activation retry pacing (consumed by TunnelsManager+Activation).
    // Injected with production defaults for the same reason
    // `currentUser` is: a contract that only expresses itself over the
    // full ladder cannot be measured in a test that has to finish, and
    // the alternative is a guard nobody drives.
    let retryInterval: TimeInterval
    let maxRetries: Int

    /// The deadline rung 0's foreign-slot pre-flight rides. Fixed
    /// rather than paced: it bounds two vault reads, which take what
    /// they take whatever the ladder's pacing is.
    let preflightBudget: TimeInterval = 2

    /// How long one attempt may stay unresolved before the manager
    /// withdraws it.
    ///
    /// Not a bound on a rung's work — it cannot be, since two of a
    /// rung's steps are NE round-trips with no deadline of their own,
    /// and one of those is exactly what this exists to catch. It is a
    /// deadline chosen to sit comfortably past the ladder's own pacing,
    /// so a climb that is still moving always mints a new attempt id
    /// (retiring the previous rung's watchdog) long before this
    /// expires. The pre-flight's budget is added because it is fixed
    /// rather than paced: at short pacing it would otherwise be most of
    /// the ceiling.
    var activationCeiling: TimeInterval {
        Double(maxRetries + 1) * retryInterval + preflightBudget
    }

    /// Tunnels whose `remove()` is in flight. Every mutation gate is
    /// barred for them: the removal suspends for seconds with its
    /// sheet still on screen, and an activation — or a save from the
    /// editor — started inside that window would re-arm or re-write an
    /// entry that is about to be deleted, which is how a system entry
    /// outlives the app's list.
    @ObservationIgnored private(set) var removingIds: Set<UUID> = []

    // MARK: - Factory

    static func create(vault: TunnelVaultClient) async throws -> TunnelsManager {
        let factory = RealTunnelProviderFactory()
        let providers = try await factory.loadAllFromPreferences()
        // Build empty, then ingest through the ownership boundary so the
        // boot list is already scoped to this user — no foreign entry is
        // ever shown, not even for the first frame.
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
        // The status observer above is deliberately NOT governed by the
        // flag — it is how any session, driven or real, reaches the
        // rows. What the flag governs is the two RELOAD triggers: a
        // configuration change anywhere in the system, and a return to
        // the foreground. Production always observes them. The DEBUG
        // harness steps that hold a rig open across a long window opt
        // out — a real reload passes their rows through the ownership
        // boundary, and a synthetic row the vault does not back reads
        // as another user's and is dropped, so an app switch mid-step
        // could empty the very list the step is measuring. The
        // short-lived side rigs keep the default and carry environment
        // exemptions instead.
        // Injected for the same reason the ladder's pacing is: the
        // contract cannot be measured under a trigger the step cannot
        // schedule.
        if observesSystemChanges {
            startObservingTunnelConfigurations()
            startObservingForeground()
        }
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

    func add(config: TunnelConfig) async throws -> TunnelContainer {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw TunnelManagementError.tunnelInvalidName
        }
        if tunnels.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw TunnelManagementError.tunnelAlreadyExistsWithThatName
        }

        try await purgeVaultDuplicates(of: config)

        // From the vault write until the entry lands, this id is
        // reconcile's blind spot — mark it in flight.
        creatingIds.insert(config.id)
        defer { creatingIds.remove(config.id) }

        // Secrets first. A tunnel entry whose vault payload is missing
        // cannot start, so the vault write gates the whole operation —
        // and a failure here leaves the system exactly as it was.
        guard await vault.store(config, attempts: 3) == .done else {
            throw TunnelManagementError.vaultUnavailable
        }

        do {
            return try await createEntry(for: config)
        } catch {
            // Roll the vault back so a failed add leaves no orphaned
            // secrets behind.
            await vault.delete(id: config.id, attempts: 3)
            throw error
        }
    }

    // MARK: - Reconcile

    /// Restores what the system lost from the vault, because the
    /// vault is the source of truth: it holds each tunnel's whole
    /// configuration and outlives what the system keeps — macOS drops
    /// a tunnel's NetworkExtension configuration when its provider
    /// extension is uninstalled.
    ///
    /// A payload with no system entry is recreated, unprompted: the
    /// user has nothing to decide, the tunnel exists and the system
    /// simply forgot it. A projection that stopped matching its
    /// payload — a name or mode the system store missed — is
    /// rewritten in place, the vault's version winning. Nothing is
    /// ever removed here: under the ownership boundary an entry the
    /// vault does not back reads as another local user's tunnel, and
    /// `ingest` has already kept it out of this list.
    ///
    /// Every restore rests on the vault having actually answered. A
    /// vault that cannot be reached teaches us nothing — there is no
    /// telling what should be put back — so the pass simply does not
    /// run.
    @discardableResult
    func reconcileFromVault() async -> Int {
        // Idempotent by construction — it only creates entries the
        // vault backs and the system lacks, and rewrites a projection
        // only when it differs, so a second pass over an unchanged
        // world does nothing. Purely additive: the ownership boundary
        // in `ingest` already scopes the list to what this user's vault
        // backs, so there is nothing to remove here — and an unbacked
        // system entry could not be told apart from another local
        // user's tunnel anyway. The flag is about overlap, not
        // repetition: a pass in flight must finish before the next one
        // reads the list it is still adding to.
        guard !isReconciling else { return 0 }
        isReconciling = true
        defer { isReconciling = false }

        guard case .configs(let payloads) = await vault.readAll() else {
            NSLog("[vault] reconcile skipped — the vault did not answer")
            return 0
        }

        let known = Set(tunnels.map(\.id))
        let missing = payloads
            .filter { !known.contains($0.id) && !creatingIds.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }

        var restored = 0
        for config in missing {
            // `known` is a snapshot. An import finishing mid-pass — or
            // a bulk answer that carried the same id twice — would land
            // a config here whose tunnel already exists, and creating a
            // second entry for the same id is the one thing this pass
            // must never do. The live list is the authority.
            guard !tunnels.contains(where: { $0.id == config.id }) else { continue }

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

        await realignDriftedProjections(with: payloads)

        if restored > 0 {
            NSLog("[vault] reconcile restored \(restored) tunnel(s) the system had lost")
        }
        return restored
    }

    /// Realigns entries whose projection no longer matches their
    /// payload — the drift `modify` leaves behind when the vault write
    /// lands and the preference save fails. The vault's version wins:
    /// name and mode are rewritten onto the system entry in place.
    ///
    /// `createdAt` is deliberately not compared: nothing can change
    /// it, and the two stores round-trip the date through different
    /// epochs, so exact equality would misfire on precision noise and
    /// turn every pass into a save. Active tunnels are left alone,
    /// as everywhere in this pass — the drift waits for the session
    /// to end. A realign that would collide with another tunnel's
    /// name is skipped the same way a restore would be.
    private func realignDriftedProjections(with payloads: [TunnelConfig]) async {
        for config in payloads {
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

            // Read at ISSUE, like every other deferred writer here.
            // This loop runs after the pass's `readAll` suspension and
            // then writes the SYSTEM store, so by now the row may be
            // under a removal or already evicted from the list — and a
            // save landing on an entry being deleted re-mints it, while
            // one landing on a row the list no longer holds writes for
            // nobody. Until this bar existed, the realign was the only
            // store-writing path on either side with none.
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
                // Put the projection back to what the store actually
                // holds — the same rollback `modify()` documents as
                // load-bearing, and load-bearing here for a sharper
                // reason. The two lines above wrote the new identity
                // into the provider BEFORE the save, and the drift test
                // at the top of this loop reads exactly that memory
                // (`tunnelIdentity`), so a refused save left the
                // projection agreeing with the vault while the SYSTEM
                // still held the old name: the test could never fire
                // again and the drift became permanent instead of
                // waiting for the next pass.
                try? await tunnel.tunnelProvider.loadPreferences()
                NSLog("[vault] reconcile could not realign \(config.id): \(error.localizedDescription)")
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
    ///
    /// A vault that cannot answer aborts the write instead of being
    /// skipped: letting a write proceed past an unanswered dedup is
    /// the one way a name collision can ever be born.
    private func purgeVaultDuplicates(of config: TunnelConfig) async throws {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard case .configs(let payloads) = await vault.readAll() else {
            throw TunnelManagementError.vaultUnavailable
        }

        for other in payloads where other.id != config.id {
            let otherName = other.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard otherName.caseInsensitiveCompare(name) == .orderedSame else { continue }
            // A failed delete must abort the write: letting it proceed
            // past an unanswered dedup is the one way a name collision
            // can be born — exactly what this method's contract forbids.
            guard await vault.delete(id: other.id, attempts: 3) == .done else {
                throw TunnelManagementError.vaultUnavailable
            }
            NSLog("[vault] dropped stale payload \(other.id) that claimed the name '\(name)'")
        }
    }

    /// Creates and persists the system entry for a config, then adds
    /// it to the list. Shared by `add` and the reconcile restore path.
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
        // Barred during removal like the activation gates, and for a
        // sharper reason: this path WRITES THE PAYLOAD BACK. Landing
        // between the delete and the entry removal, it restores the
        // very secret that was just erased, and the next reconcile
        // finds a payload without an entry and rebuilds the tunnel the
        // user deleted. A save the user asked for deserves an error,
        // not a silent no-op.
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

        // Same ordering as `add`. If the preference save fails after
        // this, the vault holds the edit while the identity projection
        // stays stale — the tunnel still starts from the new payload,
        // and the next reconcile pass realigns the projection.
        guard await vault.store(config, attempts: 3) == .done else {
            throw TunnelManagementError.vaultUnavailable
        }

        tunnel.tunnelProvider.localizedDescription = name
        tunnel.tunnelProvider.isEnabled = true
        tunnel.tunnelProvider.configure(with: config.identity)

        do {
            try await tunnel.tunnelProvider.savePreferences()
            try await tunnel.tunnelProvider.loadPreferences()
        } catch {
            // Put the projection back to whatever the store actually
            // holds. The three lines above wrote the edit into the
            // provider BEFORE the save, so a refused save leaves this
            // process believing an identity the system never accepted
            // — and that lie is load-bearing: reconcile detects a
            // stale projection by comparing the vault payload against
            // exactly this value, so it would find them in agreement
            // and skip the repair the failure just made necessary. If
            // the re-read fails too the drift survives, and then the
            // only cure left is the user editing the tunnel again.
            try? await tunnel.tunnelProvider.loadPreferences()
            throw TunnelManagementError.vpnSystemErrorOnModifyTunnel(systemError: error)
        }

        tunnel.name = name
    }

    func remove(tunnel: TunnelContainer) async throws {
        // Removal suspends for seconds below (three vault attempts,
        // then the system entry), and the sheet that asked for it
        // stays on screen the whole time — `deleteTunnel` only
        // dismisses after this returns. So the window is not just
        // "what was already running", it is "anything the user can
        // still press". Three withdrawals, in order of what they
        // actually stop:
        //
        // 1. The door is barred for this id. Clearing the attempt id
        //    alone would not have done it: a FRESH activation writes
        //    its own id and undoes every flag below, and one tap on
        //    the toggle while this call hangs is enough. With the id
        //    listed here, both entrances refuse it.
        //    One removal per id, and a second entrance is a SILENT
        //    no-op. The latch is a set, so whichever call finished
        //    first would lower it for both — and every deferred writer
        //    on these paths reads exactly that latch to decide whether
        //    it may still write, so the second half of an overlapping
        //    pair would run with its own bar already down. Nothing is
        //    thrown because nothing went wrong: the detail sheet stays
        //    up for the seconds this takes and its button can be
        //    pressed again, and an error banner over a deletion that IS
        //    happening would be a lie the user has to act on.
        guard !removingIds.contains(tunnel.id) else { return }
        removingIds.insert(tunnel.id)
        defer { removingIds.remove(tunnel.id) }
        // 1b. Then the rung already in flight is waited out, BEFORE
        //     anything is deleted. NE round-trips are not cancellable,
        //     so a `savePreferences` on its way to the system cannot be
        //     recalled; landing after our `removePreferences` it
        //     re-mints the entry, and with `armRecovery` in the same
        //     rung it comes back ARMED with its payload gone —
        //     invisible, undeletable, self-reconnecting. Waiting here
        //     rather than after the vault delete is what makes the
        //     ceiling safe to enforce: nothing is half-deleted yet, so
        //     a wedged call answers "could not delete, try again"
        //     instead of leaving an entry no one can decode. The bar
        //     above already keeps a NEW rung from taking its place.
        //     The stop's own disarm is waited out in the same breath
        //     and for the same reason. The delete flow issues the stop
        //     FIRST and the removal second, so that task is already
        //     queued when the bar goes up: the gate reads the bars when
        //     the save is issued, finds none, and its save can then
        //     land after `removePreferences` — re-minting the entry
        //     this call is deleting. One bounded wait covers both.
        let rungSettled: Bool? = await bounded(20) {
            await tunnel.activationRungTask?.value
            await tunnel.pendingDisarmTask?.value
            return true
        }
        guard rungSettled == true else {
            throw TunnelManagementError.vpnSystemErrorOnRemoveTunnel(
                systemError: Self.noSystemDetail(LocalizationManager.shared.t("error_detail_timeout")))
        }
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
        //
        // Nothing has been withdrawn from the tunnel at this point,
        // and that is deliberate: on the failure below it keeps its
        // ladder, its retry and its revive, exactly as if the user had
        // never asked. An earlier version withdrew first and left a
        // surviving tunnel frozen mid-activation with nothing running
        // to move it — a worse outcome than the failure it reported.
        guard await vault.delete(id: tunnel.id, attempts: 3) == .done else {
            throw TunnelManagementError.vaultUnavailable
        }

        // 2. Past this line the tunnel's secret is gone and there is no
        //    tunnel left to activate, so now the intent comes down.
        //    Every rung re-reads the attempt id after its await, so
        //    `nil` fails them closed; the scheduled retry, the one task
        //    we hold a handle to, is cancelled outright. Clearing
        //    `isAttemptingActivation` also keeps the teardown's own
        //    `.disconnected` from reading as a mid-activation drop and
        //    handing this entry to the drop belt mid-deletion.
        tunnel.isAttemptingActivation = false
        tunnel.activationAttemptId = nil
        tunnel.activationTask?.cancel()
        tunnel.activationTask = nil
        // A pending revive must not outlive the entry it would raise.
        tunnel.respawnReviveConsumed = true
        tunnel.respawnReviveTask?.cancel()
        tunnel.respawnReviveTask = nil

        // The rule comes down before the entry does, and this is not
        // belt-and-braces — it is the only place that can do it for
        // the common case. Armed-and-inactive is a NORMAL resting
        // state here: both the anonymous drop and the exhausted ladder
        // keep their rule on purpose, and a tunnel in that state skips
        // `startDeactivation` entirely when the user deletes it (the
        // delete flow only stops what is running). Leave it, and a
        // failed `removePreferences` below strands an entry that is
        // armed, payload-less, hidden from the list by the ownership
        // filter, and retried by the OS on every network change.
        // Sequential await, so nothing here can outrun the removal.
        if let disarmError = await Self.standDownRecovery(on: tunnel.tunnelProvider) {
            NSLog("[remove] recovery rule stayed armed on \(tunnel.name) — \(disarmError.localizedDescription)")
        }

        // Half-deleted from here on: the payload is gone, so a failure
        // below leaves an entry the app can no longer decode. The next
        // ingest reads `.missing` for it and files it under another
        // user, which hides it from the list — the throw is the only
        // notice the user gets that something is still in System
        // Settings. Nothing paints the row here on purpose: the status
        // it carries was written by this manager, not observed, and
        // overwriting it with a session reading would erase a
        // `.waiting` queue slot or dress an armed entry as idle.
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

        // A queue slot must not outlive the list it was queued in. The
        // removal may have taken the very session the queued tunnel was
        // waiting behind, in which case its turn is now; or the slot
        // may have gone stale, in which case the hand-off's own guards
        // clear it. Both answers are better than leaving it: before the
        // status gate a later reload repainted the orphan `.inactive`,
        // and that accidental repair is exactly what the gate removed.
        //
        // Safe for the unrelated-tunnel case only because the hand-off
        // now tests the slot itself: deleting a bystander while another
        // tunnel is still up leaves the queue exactly where it was.
        // No-op when the removed tunnel WAS the queued one, since the
        // line above just cleared the slot.
        activateWaitingTunnelIfNeeded()
    }

    /// The uninstall flow's hand on the refresh machinery: from this
    /// call on, no debounced reload runs in this process until
    /// `resumeRefresh()`. See `refreshSuspended` for why the teardown
    /// must own the store.
    func suspendRefreshForUninstall() {
        refreshSuspended = true
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    /// Lowers the uninstall latch when the process provably returns
    /// to list-world — a failed teardown, or extensions reactivated
    /// from the gate — and runs one refresh so the list re-proves
    /// itself against the store it stopped watching.
    func resumeRefresh() {
        guard refreshSuspended else { return }
        refreshSuspended = false
        scheduleRefresh()
    }

    /// Uninstall support, computed while the vault still answers: the
    /// ids whose entries the teardown may remove — exactly the set a
    /// reinstall provably restores (reconcile rebuilds entries from
    /// the DECODED payload set). A custody row's entry stays: it is
    /// the only anchor that makes a present-but-undecodable payload
    /// visible again after a reinstall — ingest rescues it off the
    /// entry, reconcile could never restore it. Unverifiable reads
    /// keep their entries for the same reason.
    func removableEntryIds() async -> Set<UUID> {
        var ids = Set<UUID>()
        for tunnel in tunnels {
            if case .config = await vault.read(id: tunnel.id) {
                ids.insert(tunnel.id)
            }
        }
        return ids
    }

    /// Uninstall's last step: removes the classified entries from the
    /// system store, off a FRESH system list — so an entry a
    /// mid-teardown pass managed to mint is caught too, and no stale
    /// provider object is replayed. Best-effort by design: a survivor
    /// is inert without the extensions, hidden from the list by
    /// ingest, and self-heals on reinstall (payload present — an
    /// existing entry is adopted, a missing one restored by
    /// reconcile; both converge).
    func removeEntriesForUninstall(_ removableIds: Set<UUID>) async {
        guard let providers = try? await providerFactory.loadAllFromPreferences() else {
            NSLog("[uninstall] entry removal skipped — the system list did not load")
            return
        }
        for provider in providers {
            guard let id = provider.tunnelIdentity?.id, removableIds.contains(id) else { continue }
            do {
                try await provider.removePreferences()
            } catch {
                NSLog("[uninstall] entry removal failed for \(provider.localizedDescription ?? id.uuidString): \(error.localizedDescription)")
            }
        }
    }

    /// Stand-in for the rare paths where the system hands us no error
    /// object; carries a localized description so the alert's `%@`
    /// slot stays honest instead of printing a fabricated code.
    /// Internal, not private: `TunnelsManager+Activation` shares it.
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

    // Sealed at size: the attempting/non-attempting split and the drop
    // belt inside it are one reviewed narrative — the branch ordering
    // IS the doctrine the surrounding comments prove.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func handleStatusChange(for tunnel: TunnelContainer) {
        let systemStatus = tunnel.tunnelProvider.connectionStatus

        if tunnel.isAttemptingActivation {
            switch systemStatus {
            case .connected:
                tunnel.isAttemptingActivation = false
                tunnel.activationTask?.cancel()
                tunnel.activationTask = nil
                tunnel.status = .active
                // The other rising write in the app, and the one that
                // does not pass through the status gate — so it carries
                // the same rule by hand: a session that came up wears no
                // verdict from the attempt that failed before it.
                tunnel.clearErrorOnRise()

            case .disconnected:
                // Captured before the bookkeeping resets: "the session
                // died while a start was genuinely in flight" is the
                // respawn-revive discriminator — a user-initiated stop
                // travels through `.deactivating` and never reads as
                // mid-activation here.
                // The first half of that sentence is already true —
                // this whole branch sits inside `if
                // tunnel.isAttemptingActivation` — so the status is
                // the entire discriminator, and saying so keeps the
                // next reader from hunting for a second condition.
                let droppedMidActivation = tunnel.status == .activating || tunnel.status == .reasserting
                tunnel.isAttemptingActivation = false
                tunnel.activationTask?.cancel()
                tunnel.activationTask = nil
                tunnel.status = .inactive

                if tunnel.lastActivationError == nil {
                    // The system dropped the session mid-activation.
                    // Its own record of why — the extension's start
                    // failure — beats any synthesized stand-in; the
                    // attemptId guard keeps a slow fetch from writing
                    // over a newer activation round.
                    let attemptId = tunnel.activationAttemptId
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // Collision first: when another local user's
                        // session holds the slot, the disconnect record
                        // reads as noise ("session ended") — name the
                        // real cause, and stand our recovery rule down
                        // so an armed connect-on-any-network rule stops
                        // feeding the cross-user fight. The verdict is
                        // sampled at check time, not drop time: a
                        // transient drop that loses the freed slot to
                        // the other user's rule inside this window gets
                        // the collision label too — acceptable, since
                        // with a foreign holder present the gate's
                        // engage sweep would stand the same rule down
                        // anyway. Every other drop cause keeps the
                        // transient keep-armed contract — with the same
                        // exception the ladder's own give-up carries: if
                        // a tunnel is queued, the hand-off this branch
                        // triggers climbs rung 0, and rung 0's sweep
                        // hands the rule to the tunnel starting now.
                        // Full patience on purpose: no user is blocked
                        // behind this belt, and a slow-but-eventual
                        // foreign proof must still stand the armed
                        // rule down. The revive decision below does
                        // queue behind it — acceptable, because every
                        // stage is transport-bounded and the tail
                        // still lands inside the respawn window.
                        if case .heldByForeign = await self.foreignSlotVerdict() {
                            // Three facts, not one, and each was
                            // learned the hard way: the attempt must
                            // still be this one, the row must still be
                            // down (the OS can revive a tunnel while a
                            // slow verdict is fetched, and writing a
                            // failure under a green session is a lie),
                            // and the entry must still exist (a save
                            // onto a tunnel being deleted re-mints it).
                            // Two decisions with two different tests,
                            // and folding them into one guard was a
                            // regression: the rule came down only when
                            // the row happened to still be idle, so a
                            // slow-but-proven foreign holder — the
                            // exact case the unbounded verdict above
                            // exists to catch — left our rule armed
                            // and feeding the cross-user fight.
                            //
                            // Standing the rule down answers to the
                            // EVIDENCE: a proven holder means our
                            // armed rule is fuel, whatever the row is
                            // doing by now. It stops only for entries
                            // we must not write to at all — the
                            // gate's bar, read at issue time.
                            if case .barred = await self.guardedStandDown(tunnel, context: "after a proven foreign holder") {
                                return
                            }
                            // The error belongs to the ROW, so it
                            // answers to the row: only an attempt that
                            // is still current, still unexplained and
                            // still down may wear it. A tunnel the OS
                            // has since revived must not be labelled a
                            // failure under a green session.
                            guard tunnel.activationAttemptId == attemptId,
                                  tunnel.lastActivationError == nil,
                                  tunnel.status == .inactive else { return }
                            tunnel.lastActivationError = .foreignSlotHolder
                            return
                        }
                        // Bounded: this call carries no timeout of its
                        // own, and the same dark window that dropped
                        // the session can hang it forever. Two levels
                        // come back and both matter — `.some(.some)`
                        // is a record, `.some(.none)` is the system
                        // saying there was none, and `nil` is the
                        // system not saying anything at all.
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
                        // Neither branch below is "the system told us
                        // nothing happened": a deadline is ignorance,
                        // not evidence. They share the revive because
                        // ignorance here has one overwhelmingly likely
                        // cause — the extension respawn window that
                        // makes the fetch hang in the first place — but
                        // they must not share a sentence, so the
                        // stand-in each of them leaves says which one
                        // it was. The record a late answer would have
                        // carried is genuinely lost; what is no longer
                        // lost is the difference between losing it and
                        // never having one.
                        let unanswered = fetched == nil
                        let standIn = Self.noSystemDetail(LocalizationManager.shared.t(
                            unanswered ? "error_detail_timeout" : "error_detail_session_ended"))
                        // Anonymous drop: no foreign holder and no
                        // system record. Mid-activation this is the
                        // respawn-window class (field-measured up to
                        // ~10s after a teardown), and the OS's own
                        // on-demand revival is not guaranteed without
                        // a network event. Sequenced HERE — after the
                        // record hunt came up empty — so a real
                        // failure's record can never be raced into a
                        // retry. Spend the single per-intent revive
                        // through `beginActivation` — the full
                        // machinery below the granting door, so a
                        // revived attempt can never re-grant itself;
                        // once spent, record the honest stand-in.
                        if droppedMidActivation, !tunnel.respawnReviveConsumed {
                            tunnel.respawnReviveConsumed = true
                            tunnel.respawnReviveTask = Task { @MainActor [weak self] in
                                try? await Task.sleep(for: .seconds(1))
                                // Cancellation is the one silent exit,
                                // and it is silent on purpose: it only
                                // happens when the user withdrew the
                                // intent (a stop, a delete, a newer
                                // start) and their own action is the
                                // explanation.
                                guard let self, !Task.isCancelled else { return }
                                guard tunnel.activationAttemptId == attemptId,
                                      tunnel.status == .inactive,
                                      tunnel.lastActivationError == nil,
                                      !self.removingIds.contains(tunnel.id),
                                      self.tunnels.contains(where: { $0 === tunnel }),
                                      !self.tunnels.contains(where: { $0.id != tunnel.id && $0.status != .inactive })
                                else {
                                    // Granted but unspendable — most
                                    // often because a queued tunnel
                                    // took the slot in the meantime.
                                    // The drop that armed it is still
                                    // unexplained, and the belt's exit
                                    // above skipped the stand-in on
                                    // the promise that this revive
                                    // would speak. A toggle that falls
                                    // back to off with no error and no
                                    // retry is the single outcome this
                                    // whole belt exists to prevent, so
                                    // the promise is kept here.
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

                // This tunnel may be the one a queued tunnel was waiting
                // to replace; its failure is that tunnel's turn — the
                // same hand-off the non-attempting `.inactive` path does.
                activateWaitingTunnelIfNeeded()

            case .connecting:
                tunnel.status = .activating

            case .disconnecting:
                tunnel.status = .deactivating

            case .reasserting:
                tunnel.status = .reasserting
                // The third rising write, carrying the same rule by
                // hand for the same reason as `.connected` above: it
                // does not pass through the status gate.
                tunnel.clearErrorOnRise()

            default:
                break
            }
        } else {
            // No attempt of ours is in flight, so the reading is the
            // system's to give: an on-demand revival, a stop from
            // System Settings, a drop under a session we had stopped
            // watching — and, most often of all, the tail of a stop we
            // issued ourselves. That last one lands here because the
            // flag came down when the session CONNECTED (the branch
            // above), so by the time the user stops a running tunnel
            // there is no attempt left to be in flight; for a stop
            // issued before that, `startDeactivation` lowers it
            // synchronously. Either way it is the hand-off below that
            // this branch owes the queued tunnel. The row follows the
            // reading through the gate that knows which states are ours
            // to keep (`refreshStatus`), so a reading that only means
            // "no session" can no longer take a queued tunnel's turn
            // away. A reading that says a session EXISTS still lands,
            // here as everywhere: if the system has somehow started a
            // queued tunnel out of band, that is news and the row says
            // so.
            //
            // Deliberately belt-less, and this is the accepted limit
            // rather than an oversight: a session that dies after it
            // connected is most often a network that went away, and the
            // armed recovery rule is the answer to that. Writing a
            // failure for every such drop would put red on the routine
            // case, and the app has nothing truer to say than what the
            // row already shows.
            tunnel.refreshStatus()

            if tunnel.status == .inactive {
                activateWaitingTunnelIfNeeded()
            }
        }
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
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
    }

    /// Coming back to the foreground is the catch-all trigger: it
    /// covers any change that happened while the app was in the
    /// background without a notification reaching it. Same door as
    /// the configuration observer — one refresh semantic, coalesced.
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

    /// Trailing-edge debounce: a new trigger restarts the window, the
    /// pass runs once the burst goes quiet.
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
        // The list now mirrors this user's slice of the system store;
        // put back whatever the vault says should be in it.
        await reconcileFromVault()
        // For rows with no attempt in flight, the reload is the only
        // system-derived writer that grounds the blocker WITHOUT a
        // notification: a session that ended while the app was in the
        // background leaves none, and this pass is the catch-all for
        // exactly that. (A row WITH an attempt has its own: the
        // watchdog's withdrawal re-derives and hands off at the
        // ceiling — including a row this very pass has just grounded,
        // which is why that watchdog reads the attempt ledger and not
        // the status. When it read the status, the `ingest` above was
        // the silencer: it grounded the row, the ceiling then found it
        // "resolved", and the attempt ended with no error, no hand-off
        // and its recovery rule still armed.) It grounds the blocker, and
        // the status gate rightly refuses to touch the queued row — so
        // without this line the slot would survive with nothing left to
        // start it. The hand-off tests both the slot and the queued
        // row's membership itself, so on the ordinary pass, where
        // nothing changed, it is a no-op.
        activateWaitingTunnelIfNeeded()
    }

    #if DEBUG
    /// Runs one reload pass on demand — the harness's deterministic
    /// stand-in for the debounced refresh triggers. Production reaches
    /// `reload()` only through `scheduleRefresh`'s trailing window; a
    /// test proving list behavior across a reload cannot hang its
    /// verdict on wall-clock timing, so this exposes the exact same
    /// pass, nothing more.
    func refresh() async {
        await reload()
    }

    /// Aligns the list from a fresh system read WITHOUT reconciling —
    /// the teardown nets' surface. A net that just removed an entry
    /// must prune the mirror deterministically, but running the full
    /// reload there would let reconcile MINT entries for any decodable
    /// payload a later net is still due to sweep: teardown must never
    /// create what teardown exists to remove. Production's own entry
    /// removals — `remove()` and the uninstall sweep — prune or
    /// rebuild the list by their own hands; this stays a harness
    /// surface.
    func prune() async {
        guard let providers = try? await providerFactory.loadAllFromPreferences() else { return }
        await ingest(providers)
        // Slot hygiene without a start: a queue slot whose row this
        // prune just dropped would otherwise dangle with nothing left
        // to clear it — but starting a session is a decision teardown
        // must never make, so this clears and never hands off.
        if let waiting = waitingTunnel, !tunnels.contains(where: { $0 === waiting }) {
            waitingTunnel = nil
        }
    }
    #endif

    /// The single boundary where system-wide NE providers become THIS
    /// user's tunnels. The system extension and its NE configurations
    /// are system-wide, so `providers` can carry another local user's
    /// entries; only those the owner-scoped vault confirms as ours are
    /// materialized. Foreign entries never enter the model, so nothing
    /// downstream — the list, the detail/control surface, or reconcile
    /// — can show, drive, or delete them. Matching stays by persisted
    /// identity so containers the views already hold survive.
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

    /// Keeps only the providers whose configuration this user owns, per
    /// the owner-scoped vault. When the vault cannot answer, ownership
    /// is unverifiable, so it stays conservative: it keeps the providers
    /// already known to be ours and reveals no unverified (possibly
    /// foreign) one during that window, rather than flashing a stranger.
    ///
    /// readAll's answer is only the DECODED set — a payload that is
    /// present but unreadable is excluded from it, and that is exactly
    /// the payload custody must keep visible (the detail screen's
    /// "config unavailable" surface is reachable only through the list
    /// row). So a provider absent from the decoded set is not condemned
    /// on that evidence alone: a per-id read disambiguates. The daemon
    /// scopes reads by owner, so `.missing` is a verdict — not this
    /// user's — while `.undecodable` means ours-but-broken, a custody
    /// problem to surface, never an entry to hide. The probe costs one
    /// XPC round-trip per unmatched provider, runs only when unmatched
    /// providers exist at all, and the first dark answer short-circuits
    /// the rest of the pass into the cached-keep rule so a respawning
    /// vault costs one timeout, not one per entry.
    ///
    /// The single line it logs when it drops or rescues something is
    /// the field signal that isolation is doing its job on a shared
    /// machine — quiet on a single-user Mac, and it names the uid it
    /// scoped to.
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
        // One .unreachable verdict flips the rest of the pass to the
        // same conservatism a failed readAll gets: a single timeout
        // bounds the stall, and unproven entries hold back rather than
        // pay their own timeout each — or flash a stranger.
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
                // Landed between readAll and this probe — ours.
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

    /// Asks whether the system's one VPN slot is held by another local
    /// user's session. Shares `SlotClassifier` with the connection
    /// gate, so the gate and the activation belts can never disagree
    /// on what a foreign holder is. Unverifiable states answer `.free`
    /// — refusing an activation on evidence that never arrived would
    /// be worse than letting the system report the failure itself.
    /// The same doctrine makes a deadline safe where a caller opts in:
    /// an answer that has not arrived by `seconds` IS an unverifiable
    /// state. The two callers with a user still waiting behind an
    /// `.activating` row opt in (the rung-0 pre-flight and the
    /// start-catch, both on `preflightBudget`) — fail-open converges
    /// there, because their exits stand rules down on their own. The
    /// drop belt keeps the default unbounded patience: it alone
    /// runs post-mortem, and a slow-but-eventual foreign proof must
    /// still stand the armed rule down.
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

    /// Races a producer against a deadline through a one-shot resume
    /// — the same shape as the vault client's transport races, and
    /// deliberately NOT a task group: a group scope awaits all its
    /// children on exit, so with an uncancellable producer it would
    /// bound only the returned value, never the caller's wait. Here
    /// the caller genuinely resumes at the first finish; the losing
    /// producer keeps running detached (XPC round-trips are not
    /// cancellable) and its answer is dropped. `nil` means the
    /// deadline won — the evidence never arrived — and every caller
    /// falls back to the meaning its doctrine gives an unverifiable
    /// state.
    ///
    /// Internal rather than private: the activation extension's
    /// uninstall sweep waits out in-flight rungs through it, the same
    /// way `remove()` does.
    /// The producer returns a NON-optional `T`, so the optional this
    /// hands back has exactly one meaning: nil is the deadline, never
    /// an answer. A producer whose own answer is optional (the
    /// disconnect record is the live example) comes back as `T??` and
    /// the caller reads the two levels apart — "the system said there
    /// was nothing" and "the system never said" are different facts,
    /// and flattening them into one nil is how a real failure was once
    /// filed as an anonymous drop.
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
