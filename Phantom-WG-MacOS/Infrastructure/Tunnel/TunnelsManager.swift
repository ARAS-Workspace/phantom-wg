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
/// `creatingIds` marks two different sentences under one set — an
/// import's "this tunnel is on its way to the list", raised one id at
/// a time, and a restore pass's "a pass in flight is deciding about
/// this payload", raised over its whole candidate set and just as
/// often ending in a skip — which together keep a pass from minting a
/// second entry for a marked id and keep a concurrent write's
/// duplicate purge from reading their payloads as orphans. The
/// debounced refresh coalesces the system's change-notification bursts
/// into single reload+reconcile passes.
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

    /// Ids a write has spoken for. The two writers mean different
    /// things by it and both are load-bearing: an add's mark says the
    /// entry is on its way, while a restore pass's says a pass in
    /// flight is deciding about that payload — a decision that ends in
    /// a skip as readily as in an entry, when the name turns out to be
    /// taken or the payload turns out to be gone. A reader that treats
    /// membership as "an entry is imminent" will be wrong for the
    /// majority of a restore's marks. An add puts the payload in the vault before
    /// `savePreferences` lands the entry, and a reconcile pass
    /// squeezing into that gap — off a change notification whose reload
    /// still read the old, emptier list — sees "payload with no entry"
    /// and mints a second one. Field-measured on a first import; this
    /// set forbids it.
    ///
    /// Two readers now, and the second is why a restore marks itself
    /// too: "payload with no entry" is also what the duplicate purge
    /// reads as an orphan, and a same-name import landing inside either
    /// window would delete a payload whose tunnel is on its way to the
    /// list. A restore marks its whole candidate set, before its first
    /// PROBE — its candidates' payloads are already in the vault when
    /// the pass begins, where an add's does not exist yet, so the mark
    /// has to lead the reads rather than follow them.
    ///
    /// One leg of that is uncovered by construction, and naming it is
    /// the honest form: a pass cannot mark a candidate before it knows
    /// there is one, and candidacy is unknowable until the bulk read
    /// answers. So the pass's own `readAll` is unmarked. That window is
    /// a slice of a longer one nothing marks — from the moment the
    /// system loses an entry, through the refresh debounce and the
    /// ingest before it, and between passes entirely — which is the
    /// hidden-entry class rather than this mark's business.
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
    /// The teardown owns the store during this window; refreshes stand
    /// down instead of racing it. Two doors lower it, and they are
    /// named for what entitles each: `releaseStoreAfterUninstall` is
    /// the flow's own, called from a `defer` so every exit releases it;
    /// `releaseAbandonedStoreLatch` is the gate's, and it is a backstop
    /// rather than the primary door. The case it was written for — a
    /// flow suspended on a system approval nobody answers, whose scope
    /// therefore never ends and whose `defer` therefore never runs — is
    /// bounded at the wait itself now (`ExtensionGateController`'s
    /// deactivation carries a budget), so that flow ends and releases
    /// through the first door like every other exit.
    ///
    /// There is deliberately NO ownership flag behind that. One was
    /// tried and it enforced nothing: with the gate's door removed,
    /// nothing ever read it, so it promised a guarantee that lived only
    /// in two assignments. The entitlement is the gate's readiness
    /// itself, which is a fact about the world rather than a bit this
    /// class sets — the teardown exists to take the extensions DOWN, so
    /// their return says no teardown of theirs is running.
    ///
    /// BARRED at SIX points, counted by grepping rather than by adding
    /// one to the last number written here — it has been wrong twice.
    /// `scheduleRefresh` refuses to start a pass; `reload` re-reads it
    /// before the reconcile, whose job is to CREATE entries, and again
    /// before the queue hand-off at its tail, which raises a session
    /// and arms a rule to do it; `reconcileFromVault` re-reads it
    /// before the realign half; the mint loop re-reads it per
    /// candidate, since each iteration spends a probe and two
    /// round-trips; and the realign loop re-reads it per ROW, since
    /// each row is a system round-trip and it writes identity onto
    /// entries the teardown may be removing at that moment. Every one
    /// of those is a writer to the system store.
    ///
    /// The readers deliberately NOT barred are `ingest` and the list
    /// eviction behind it: they only ever narrow the list to what the
    /// system already holds, so they can create nothing for a teardown
    /// to miss.
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
    ///
    /// The restore reads it too, and since the removal takes the ENTRY
    /// before the payload that reader is not optional: the entry's
    /// removal broadcasts a configuration change, the reload behind it
    /// evicts the row, and a restore would then see a payload the system
    /// lacks and mint the entry straight back — into the window where
    /// the payload delete is still in flight. The bar is what keeps the
    /// pass from manufacturing the very residue the new order exists to
    /// avoid.
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

        // From the vault write until the entry lands, this id has a
        // payload and no list row. That shape has two readers now:
        // reconcile, which must not mint a second entry for it, and a
        // CONCURRENT write's run of the duplicate purge — this call's
        // own run is already past, and excludes this id anyway — which
        // would otherwise read it as an orphan and delete the payload
        // out from under a tunnel on its way to the list.
        creatingIds.insert(config.id)
        defer { creatingIds.remove(config.id) }

        // Secrets first. A tunnel entry whose vault payload is missing
        // cannot start, so the vault write gates the whole operation —
        // and a failure here leaves the system exactly as it was.
        if let failure = TunnelManagementError.forVaultWrite(await vault.store(config, attempts: 3)) {
            throw failure
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
    /// Every restore rests on the vault having actually answered, and
    /// on it still answering the same way when the entry is minted. A
    /// vault that cannot be reached teaches us nothing — there is no
    /// telling what should be put back — so the pass does not run at
    /// all, and one that goes dark partway stops minting where it
    /// went.
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
            // `removingIds` is barred here for the same reason
            // `creatingIds` is, and since the removal takes the entry
            // before the payload it is no longer optional. The entry's
            // removal broadcasts a configuration change; 400ms later a
            // reload runs while `remove()` is still inside its vault
            // delete, ingest drops the row because the entry is gone,
            // and this filter would then see a payload the system lacks
            // and mint the entry straight back — landing it just in time
            // for the delete to take the payload out from under it. That
            // is the hidden entry this pass exists to avoid, minted by
            // the pass itself.
            .filter {
                !known.contains($0.id)
                    && !creatingIds.contains($0.id)
                    && !removingIds.contains($0.id)
            }
            .sorted { $0.createdAt < $1.createdAt }

        // The whole candidate set is marked in flight here, where
        // candidacy is DECIDED, and stays marked for the pass.
        //
        // Marking each one as its turn came was not enough, and the
        // reason is the queue rather than the candidate: from this line
        // on, every candidate is a payload with no list row — precisely
        // what the duplicate purge reads as an orphan — while the loop
        // spends a probe and two NE round-trips on each one AHEAD of
        // it, handing the main actor back at every await. On an
        // extension reinstall, where the system lost many entries at
        // once and the user is looking at a short list, a re-import of
        // a name further down the queue would find its payload
        // unlisted and unmarked, and delete the only copy of that
        // tunnel's key. `add`'s mark has no such gap because its
        // payload does not exist until after the mark.
        //
        // Subtracting is safe against the only other writer there is.
        // `add` marks an id it has just minted, so it can never collide
        // with a payload the vault already holds; and the filter above
        // excluded ids already marked, so a candidate carrying someone
        // else's mark never enters this set in the first place. This
        // pass therefore only ever clears marks it raised.
        let candidateIds = Set(missing.map(\.id))
        creatingIds.formUnion(candidateIds)
        defer { creatingIds.subtract(candidateIds) }

        let (restored, attempted) = await mintMissingEntries(from: missing)

        // The realign half reads the SNAPSHOT, which is older than
        // every mint above — so a row this pass just wrote from a
        // fresher read would be found "drifted" against the stale name
        // and rewritten back to it, the pass undoing its own work one
        // line later. Comparing a just-minted row against this array
        // measures the age of the snapshot rather than any drift, so
        // those rows sit this half out; if one of them really has
        // drifted since, the next pass reads a snapshot new enough to
        // say so.
        // And the realign half is barred by the same latch, because it
        // is a WRITER too: it saves identity onto entries the teardown
        // may be removing at this very moment, and a save landing after
        // a removal re-mints the entry it just took. The mint loop's
        // own bail does not cover this — it breaks out and lands here.
        guard !refreshSuspended else { return restored }
        await realignDriftedProjections(with: payloads, skipping: attempted)

        if restored > 0 {
            NSLog("[vault] reconcile restored \(restored) tunnel(s) the system had lost")
        }
        return restored
    }

    /// The two things the live list has to say before a proven payload
    /// becomes an entry, both read in the same breath as the mint.
    ///
    /// Synchronous on purpose: these tests are only worth what they are
    /// still true for, and an await between them and `createEntry`
    /// would be the very gap they exist to close.
    ///
    /// The ID test comes first and repeats the one at the top of the
    /// iteration, because the probe between them suspended. Before the
    /// probe existed the two lines were adjacent and one reading served
    /// both; a reload
    /// landing in the probe's window can list the very id being proven
    /// — an entry the ownership boundary held back in an earlier dark
    /// window is the shape that does it — and minting on the older
    /// reading would create the second entry for one id that the pass
    /// must never create. What this reading still does NOT survive is
    /// `createEntry`'s own two round-trips, and that residue is closed
    /// where it lives rather than here: `createEntry` reads the list
    /// once more before it appends, and hands back the row an ingest
    /// landing in that window created. So this test is the last word on
    /// whether a candidate is WORTH minting, and not on whether the
    /// append is safe — the two questions are separated by two
    /// suspensions and only one of them can be answered from here.
    ///
    /// The NAME test is the restore's share of a rule the whole app
    /// keeps: import and edit both refuse a duplicate name, so the
    /// restore must not be the one path that manufactures one. A second
    /// tunnel with the same name is indistinguishable to the operator
    /// and collides in the name-keyed accessibility identifiers. It
    /// reads the payload's CURRENT name, since that is what would be
    /// written. The payload is left in the vault rather than deleted:
    /// renaming the tunnel that holds the name frees it, and the next
    /// launch brings this one back.
    private func listAdmits(_ current: TunnelConfig) -> Bool {
        // Identity first, and not for taste: a row that carries this id
        // is refused for THAT reason whatever name it projects, and a
        // relisted row commonly projects a stale name — testing the
        // name first would refuse on the wrong ground and log a
        // sentence that describes a different problem.
        guard !tunnels.contains(where: { $0.id == current.id }) else {
            NSLog("[vault] reconcile skipped \(current.id): the list took that id while the payload was being proven")
            return false
        }
        // A removal that STARTED after candidacy was decided. The
        // candidate filter reads `removingIds` once, where candidacy is
        // settled, and that reading is a pass old by the time the mint
        // is reached — a probe and two round-trips per candidate ahead
        // of this one. Usually the id test above covers it, because a
        // removal keeps its row listed until it finishes; it stops
        // covering it the moment a concurrent reload's ingest evicts
        // that row, which the entry-first order makes ordinary rather
        // than exotic, since the entry is already gone by then. Minting
        // there hands the removal an entry it did not ask for and will
        // not take.
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

    /// What one candidate is worth at the moment its entry would be
    /// minted, as opposed to when the pass began.
    private enum ProvenPayload {
        /// Still there — and this is what it says NOW, which is what
        /// gets written.
        case mint(TunnelConfig)
        /// Not this pass's to restore. Already reported.
        case skip
        /// No answer. The caller stops minting here.
        case dark
    }

    /// Re-reads one candidate at mint time, because the pass's snapshot
    /// is older than this loop in both directions.
    ///
    /// `readAll` suspended, every candidate before this one suspended
    /// again minting its entry, and `add`/`modify` drop stale payloads
    /// while all of that runs. So a candidate is one of two opposite
    /// things by the time its turn comes: a payload the system
    /// genuinely lost (put it back) or one that has since been DELETED,
    /// where minting hands the world an entry whose secret is gone —
    /// absent from the list because `ingest`'s ownership boundary reads
    /// it as another user's, undeletable for the same reason, and
    /// self-reconnecting if it was minted armed. The snapshot cannot
    /// tell the two apart because it predates both; one read at the
    /// moment of minting can, and it is the same probe `ingest` runs
    /// one suspension after its own bulk answer.
    ///
    /// Free in the steady state: candidates exist only when the system
    /// has lost an entry the vault still backs, so an ordinary pass
    /// never calls this at all. Single attempt, never
    /// `read(id:attempts:)` — the retrying variant spends up to ~16.8s
    /// per candidate against a dark vault, and it would spend all of it
    /// holding `isReconciling`, so no later trigger could reconcile
    /// either. (The main actor is not held: the ladder's backoff
    /// sleeps, like every await here, hands it back — which is exactly
    /// why the in-flight mark above has to be raised before the first
    /// one.)
    ///
    /// What comes back to be minted is the FRESH payload, not the
    /// snapshot's copy: a rename that landed in between would otherwise
    /// be projected wrong the moment the entry is born, which is drift
    /// manufactured by the pass that exists to end it. The caller's
    /// name guard reads the fresh name for the same reason — it guards
    /// what is about to be written.
    private func provePayload(_ config: TunnelConfig) async -> ProvenPayload {
        switch await vault.read(id: config.id) {
        case .config(let fresh):
            // The vault answers with whatever body sits under THIS KEY,
            // while every decision the caller made — the candidate
            // filter, the list check, the absence being repaired — was
            // made about `config.id`. A body whose own id contradicts
            // its key would carry all of that to a different tunnel,
            // including the one guarantee the mint loop must never
            // break: that no second entry is created for an id already
            // listed. Nothing the app writes can produce it, since the
            // key IS the id the payload encodes, so it is a custody
            // anomaly to report rather than a case to normalize.
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

    /// The minting half of a reconcile pass, lifted out so the pass
    /// itself stays inside the body ruler and so this loop's three
    /// exits — a dark vault, a raised teardown latch, and a candidate
    /// the list or the payload refuses — read as one sequence.
    ///
    /// Returns what it wrote and what it TRIED to write: the realign
    /// half behind it must skip both, since a row this loop touched was
    /// written from a reading newer than the pass's own snapshot.
    private func mintMissingEntries(from missing: [TunnelConfig]) async -> (restored: Int, attempted: Set<UUID>) {
        var restored = 0
        var attempted: Set<UUID> = []
        // One dark answer stops the minting, exactly as it stops the
        // probing in `ingest`: a single timeout bounds the stall rather
        // than one per candidate, and a payload that cannot be proven
        // present is the one thing this loop must not mint from.
        var vaultWentDark = false
        for (index, config) in missing.enumerated() where !vaultWentDark {
            // A teardown that raised the latch while this loop was
            // running stops it here, for the same reason a dark vault
            // does: what this loop produces is a SYSTEM ENTRY, and
            // uninstall has already fixed the set of entries it may
            // remove. One minted after that decision is one the
            // teardown is guaranteed to leave behind, in a store the
            // user was told is clean. The check sits inside the loop
            // rather than only at the top because every iteration
            // spends a probe and two round-trips, which is ample room
            // for the latch to go up underneath it.
            guard !refreshSuspended else {
                NSLog("[vault] reconcile stopped minting at \(config.id): a teardown took the store — \(missing.count - index) candidate(s) left unminted")
                break
            }
            // `known` is a snapshot. An import finishing mid-pass — or
            // a bulk answer that carried the same id twice — would land
            // a config here whose tunnel already exists, and creating a
            // second entry for the same id is the one thing this pass
            // must never do. This reading is the cheap early-out, taken
            // before a round-trip is spent on the candidate; it does not
            // survive the probe's suspension, so `listAdmits` reads the
            // list again after it, and `createEntry` reads it a third
            // time — at the append, past its own two round-trips, which
            // is the only place left where an ingest can still get
            // between a decision and the row it produces.
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

            // Recorded BEFORE the attempt, not after it. `createEntry`
            // saves and then re-reads, and a save that lands under a
            // re-read that refuses leaves a system entry written from
            // the fresh body with no container to show for it. A reload
            // can list that entry while this pass is still running, and
            // the realign half below would then find "drift" against
            // the pass's own opening snapshot and write the stale name
            // over the fresh one — the exact undoing the skip exists to
            // prevent, reached through the failure path instead of the
            // success one. Recording an id whose save never landed
            // costs at most one pass: realign only looks at rows the
            // list holds, and the one way such a row exists is a hidden
            // entry a concurrent reload materialised, whose genuine
            // drift the next pass then repairs.
            attempted.insert(current.id)
            do {
                _ = try await createEntry(for: current)
                restored += 1
            } catch {
                // The payload stays put; the next launch tries again.
                NSLog("[vault] reconcile failed for \(config.id): \(error.localizedDescription)")
            }
        }
        return (restored, attempted)
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
    ///
    /// `skipping` carries the ids the caller reached the mint for in
    /// this same pass, landed or not. They are excluded because the
    /// payload array here is the pass's opening snapshot while those
    /// rows were written from a per-id read taken much later, so
    /// comparing them measures the age of the snapshot rather than any
    /// drift. "Or not" matters: an entry whose save landed under a
    /// re-read that refused is listed by the next reload without ever
    /// becoming a row this pass appended, and it carries the fresh name
    /// too.
    private func realignDriftedProjections(
        with payloads: [TunnelConfig],
        skipping attempted: Set<UUID>
    ) async {
        for config in payloads where !attempted.contains(config.id) {
            // The uninstall latch, read HERE rather than only before
            // this call. Each row below costs an NE round-trip, so a
            // teardown can take the store part-way down a long list —
            // and what this loop writes is identity onto entries that
            // teardown may be removing at this very moment. A guard at
            // the call site bars a realign that has not started; this
            // one bars the rest of a realign already walking.
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
                // still held the old name: the test could not fire
                // again for this row until something else read or wrote
                // its preferences, which is a far weaker guarantee than
                // "the next pass picks it up".
                try? await tunnel.tunnelProvider.loadPreferences()
                NSLog("[vault] reconcile could not realign \(config.id): \(error.localizedDescription)")
            }
        }
    }

    /// Drops any *orphaned* payload that already claims this tunnel's
    /// name. Names are unique among listed tunnels, but a payload can
    /// outlive its entry — and one of those, holding a name the user
    /// is now reusing, would otherwise sit in the vault forever:
    /// reconcile refuses to restore it (the name is taken) and nothing
    /// else ever looks at it. Writing the name is the moment the user
    /// says which tunnel owns it, so that is where the old claim goes.
    ///
    /// A vault that cannot answer aborts the write instead of being
    /// skipped: letting a write proceed past an unanswered dedup is
    /// the one way a name collision could be born HERE.
    ///
    /// "Outlive its entry" is the whole licence, and the two bars below
    /// are what hold this method to it. The name guards that run before
    /// this one read the LIST's names while this reads the VAULT's, and
    /// the two part company on their own: `modify` writes the new name
    /// to the vault first and rolls the projection back when the
    /// preference save is refused, leaving a LISTED tunnel whose
    /// payload already carries a name the list does not show. Reusing
    /// that name then walks straight past the list guard and arrives
    /// here, where the payload looks exactly like an orphan — and
    /// deleting it takes a live tunnel's only copy of its secret.
    ///
    /// So a payload is spared when its id is on the list, and equally
    /// when its id is marked in `creatingIds` — which covers two
    /// different sentences. An add's mark means "this tunnel is on its
    /// way to the list", the payload having been written seconds before
    /// its entry lands. A reconcile pass's mark means "a pass in flight
    /// is deciding about this payload", raised over its whole candidate
    /// set: it may end in a restore, or in a skip because the name is
    /// taken or the payload turned out to be gone. Sparing the second
    /// kind is deliberately generous, and the generosity outlives the
    /// pass: a genuine orphan that dodges one write's dedup is not
    /// picked up by "the next write", because the list-name guard above
    /// refuses a second import of that name before this method is ever
    /// reached. It waits for a write that does reach the dedup with
    /// that name — a save on the tunnel now holding it — or for the
    /// name to be freed. Uninstall does not collect it either, and not
    /// because of the row: that sweep removes system ENTRIES and leaves
    /// every payload where it is. A stale payload costs keychain space.
    /// The other error costs a key nothing else holds a copy of, and
    /// that is the one this method must not make.
    ///
    /// What is deliberately NOT covered, because covering it would put
    /// a system round-trip on every write: a tunnel the list does not
    /// hold and is not creating — an entry `ingest` held back in a dark
    /// vault window is the real case. Its payload still reads as an
    /// orphan here. That residue belongs to the same class as the
    /// hidden entry itself and is named with it rather than half-paid
    /// from this side.
    ///
    /// Sparing a payload can leave the VAULT holding two records with
    /// one name. That is a state the app already survives, though not
    /// because the list is incapable of showing it: the list-name guard
    /// runs at the top of `add`, and the row is appended only after
    /// this method's own vault read, the payload write and the two
    /// system round-trips that create the entry — plus a delete for
    /// every duplicate dropped — so two imports overlapping anywhere in
    /// that stretch both land, and the list DOES show one name twice.
    /// What survives the duplicate is everything downstream: reconcile
    /// refuses to restore a payload whose name is taken, realign
    /// refuses to project one, and a duplicate the user
    /// can see is one they can rename or delete. A deleted secret is
    /// not.
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
            // A failed delete must abort the write: letting it proceed
            // past an unanswered dedup is the one way a name collision
            // can be born — exactly what this method's contract forbids.
            // The two failures abort alike but do not READ alike: a
            // refusal is something answering no, while silence may yet
            // have landed. It is the LAST attempt's verdict either way —
            // the ladder returns that one — so a refusal here does not
            // establish that all three were refused. Both readings now
            // reach the user under their own names, which is why the log
            // line below is no longer the only place the difference
            // survives.
            let dropped = await vault.delete(id: other.id, attempts: 3)
            if let failure = TunnelManagementError.forVaultWrite(dropped) {
                NSLog("[vault] could not drop stale payload \(other.id) claiming '\(name)': outcome=\(dropped.label)")
                throw failure
            }
            NSLog("[vault] dropped stale payload \(other.id) that claimed the name '\(name)'")
        }
    }

    /// Creates and persists the system entry for a config, then adds
    /// it to the list — unless an ingest listed that entry while this
    /// call was suspended, in which case the list's row is handed back
    /// and nothing is appended. Shared by `add` and the reconcile
    /// restore path.
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

        // The list is read again HERE, and not because the caller might
        // have raced: the two lines above are suspensions, and the
        // system holds this configuration from the moment the first one
        // answers. An `ingest` landing in the gap rebuilds the list from
        // the system, finds an entry no row covers, and creates one —
        // so an unconditional append puts the same id on the list twice.
        // SwiftUI's `ForEach` then renders one id in two positions and
        // the name-keyed accessibility identities collide.
        //
        // Both callers open the window and neither closes it. `add`
        // marks the id in `creatingIds`, but that mark bars the restore
        // and the duplicate purge — `ingest` reads neither, and rightly:
        // it only mirrors what the system holds, and the system does
        // hold this. The restore's own `listAdmits` re-test runs BEFORE
        // these same two suspensions, so it goes stale across exactly
        // this gap.
        //
        // The listed row wins. It wraps the provider a system read
        // returned, which is the object every later reload keeps
        // re-finding; the one in hand is this process's own, describing
        // the same single configuration. Returning the list's row leaves
        // the caller holding what the list holds — the alternative,
        // replacing it, would swap the object out from under any view
        // already bound to it and gain nothing.
        if let listed = tunnels.first(where: { $0.id == config.id }) {
            NSLog("[vault] entry \(config.id) was listed while it was being created — the ingest's row stands")
            return listed
        }

        let tunnel = TunnelContainer(tunnel: provider)
        tunnels.append(tunnel)
        tunnels = Self.sortedByCreatedAt(tunnels)
        return tunnel
    }

    func modify(tunnel: TunnelContainer, with config: TunnelConfig) async throws {
        // Barred during removal like the activation gates, and for a
        // sharper reason: this path writes BOTH stores. Landing inside a
        // removal it can restore the very secret that was just erased,
        // or save an entry back over one already removed — and with the
        // entry-first order the second is the likelier half, since the
        // entry goes before the payload. Either way the next reconcile
        // finds a pair the user asked to be rid of and rebuilds it. A
        // save the user asked for deserves an error, not a silent
        // no-op.
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
            // Put the projection back to whatever the store actually
            // holds. The three lines above wrote the edit into the
            // provider BEFORE the save, so a refused save leaves this
            // process believing an identity the system never accepted
            // — and that lie is load-bearing: reconcile detects a
            // stale projection by comparing the vault payload against
            // exactly this value, so it would find them in agreement
            // and skip the repair the failure just made necessary. If
            // the re-read fails too, the projection is left agreeing
            // with the vault while the system holds neither, and the
            // realign is blind to this row for as long as that lasts.
            // It lasts until something else reads or writes this
            // provider's preferences: an activation's arm save
            // serializes the whole projection and carries the pending
            // rename into the store, a refused disarm's own re-read
            // puts the store's copy back and re-arms the drift test,
            // another edit repairs it outright, and failing all of
            // those the next launch rebuilds the row from the store.
            // No timeline is promised here on purpose — which of those
            // comes first is not this function's to know, and saying
            // otherwise has been wrong twice.
            try? await tunnel.tunnelProvider.loadPreferences()
            throw TunnelManagementError.vpnSystemErrorOnModifyTunnel(systemError: error)
        }

        tunnel.name = name
    }

    func remove(tunnel: TunnelContainer) async throws {
        // Removal suspends for seconds below, and the sheet that asked
        // for it stays on screen the whole time — `deleteTunnel` only
        // dismisses after this returns. So the window is not just
        // "what was already running", it is "anything the user can
        // still press".
        //
        // The window is now TWO vault ladders wide, not one: a read to
        // choose the order, then the entry, then a delete behind it
        // (the custody order swaps the last two). A read that answers
        // on its last attempt followed by a delete that goes dark is
        // roughly double what a single ladder cost, and every bar below
        // has to cover the longer one.
        //
        // What follows is a bar, a wait, and THREE withdrawals, in the
        // order of what each one actually stops. 1 and 1b are the bar
        // and the wait; they stop nothing themselves, they make the
        // withdrawals safe to perform:
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
        // Not a withdrawal, so it is not numbered with them: WHICH GOES
        // FIRST is decided here, by what the payload turns out to be.
        // See `entryGoesFirst(for:)` for why the order is not uniform.
        let entryFirst = try await entryGoesFirst(for: tunnel)

        if !entryFirst {
            if let failure = TunnelManagementError.forVaultWrite(await vault.delete(id: tunnel.id, attempts: 3)) {
                throw failure
            }
        }

        // 2. The intent comes down before the ENTRY goes, which is the
        //    step that matters for it: a scheduled retry landing after
        //    the entry is gone would save it straight back. In the
        //    custody order the payload delete has already run above, and
        //    that is deliberate — it is the old order preserved whole,
        //    including its property that a tunnel whose payload delete
        //    failed keeps its ladder, its retry and its revive, exactly
        //    as if the user had never asked. Every rung re-reads the
        //    attempt id after its await, so `nil` fails them closed; the
        //    scheduled retry, the one task we hold a handle to, is
        //    cancelled outright. Clearing `isAttemptingActivation` also
        //    keeps the teardown's own `.disconnected` from reading as a
        //    mid-activation drop and handing this entry to the drop belt
        //    mid-deletion.
        tunnel.isAttemptingActivation = false
        tunnel.activationAttemptId = nil
        tunnel.activationTask?.cancel()
        tunnel.activationTask = nil
        // A pending revive must not outlive the entry it would raise.
        tunnel.respawnReviveConsumed = true
        tunnel.respawnReviveTask?.cancel()
        tunnel.respawnReviveTask = nil

        // 3. The rule comes down before the entry does, and this is not
        //    belt-and-braces — it is the only place that can do it for
        //    the common case. Armed-and-inactive is a NORMAL resting
        //    state here: both the anonymous drop and the exhausted
        //    ladder keep their rule on purpose, and a tunnel in that
        //    state skips `startDeactivation` entirely when the user
        //    deletes it (the delete flow only stops what is running).
        //    Leave it, and a failed `removePreferences` below strands an
        //    entry the OS still retries on every network change —
        //    payload-less and hidden from the list in the custody order,
        //    or merely armed behind the user's back in the entry-first
        //    one. Sequential await, so nothing here can outrun the
        //    removal.
        if let disarmError = await Self.standDownRecovery(on: tunnel.tunnelProvider) {
            NSLog("[remove] recovery rule stayed armed on \(tunnel.name) — \(disarmError.localizedDescription)")
        }

        // The entry goes. What a failure here costs depends on the order
        // chosen above, and neither cost is nothing.
        //
        // ENTRY-FIRST keeps the payload: it was never touched, so the
        // tunnel's secret is safe whatever happens here. The entry is a
        // weaker claim and the comment must not overstate it — a throw
        // means the removal was not CONFIRMED, not that it did not
        // land, since NE can commit and lose the reply. What is certain
        // is the withdrawal above: the revive is spent, the ladder is
        // gone, and the recovery rule was asked to come down at step 3.
        // If that save landed the tunnel survives DISARMED; if it was
        // refused it survives ARMED with the refusal logged. Either
        // way the banner says the deletion failed and nothing tells the
        // user which of the two they now have. That is the accepted
        // price of standing the rule down before the entry, which step
        // 3 argues for: an armed entry the removal leaves behind is
        // worse than a disarmed tunnel it leaves standing, because only
        // one of the two is visible.
        //
        // The row is handed back to the system's own reading, and that
        // matters here rather than being tidiness. `remove()` writes no
        // status at all, so the row still wears whatever the last
        // writer left on it, and two of those writers leave a value the
        // provider contradicts: the exhausted ladder grounds a row FLAT
        // to `.inactive` over a session the system still holds at
        // `.connecting`, and a stop the system never answers guesses
        // `.deactivating` and never hears back. Both are terminal for
        // the user — the first refuses `startDeactivation` on its own
        // reading, the second disables Delete and Edit and parks the
        // queue behind a row that will never move. Both are also
        // non-manager-driven on their STATUS alone, so the gate is open
        // for them whatever the intent says; the withdrawal above is
        // not what admits this derive, and a `.waiting` row is still
        // rightly refused.
        //
        // In the CUSTODY order the payload is already gone, so a failure
        // here leaves an entry the app can no longer decode, hidden from
        // the list by the ownership filter, and the throw is the only
        // notice the user gets that something is still in System
        // Settings. No hand-back there: there is no tunnel left to
        // paint honestly.
        do {
            try await tunnel.tunnelProvider.removePreferences()
        } catch {
            if entryFirst { tunnel.refreshStatus() }
            throw TunnelManagementError.vpnSystemErrorOnRemoveTunnel(systemError: error)
        }

        // The payload follows, and its failure is now the recoverable
        // one: the entry is gone, so the next reload drops the row and
        // the reconcile behind it finds a payload the system lacks and
        // puts the tunnel back — whole, with its secret, for the user to
        // delete again. The row is deliberately NOT evicted here: the
        // entry's own removal already broadcast the configuration change
        // that arms that reload, and evicting first would only widen the
        // window in which the list disagrees with both stores.
        if entryFirst {
            if let failure = TunnelManagementError.forVaultWrite(await vault.delete(id: tunnel.id, attempts: 3)) {
                // The tunnel comes back — but only if something asks.
                // The configuration change the entry's removal broadcast
                // was consumed by a reload that ran while this call
                // still held the removal latch, so its restore half was
                // barred (correctly: a re-mint then would have raced
                // this very delete). Nothing else is due to fire, so the
                // payload would sit entry-less until an unrelated
                // trigger. One trailing pass is scheduled here instead;
                // it runs after this call returns and the latch is down,
                // which is exactly when the restore is safe and right.
                scheduleRefresh()
                throw failure
            }
        }

        retireFromListAndQueue(tunnel)
    }

    /// What is left once both stores are empty: the row leaves the list
    /// and the queue is answered.
    ///
    /// A queue slot must not outlive the list it was queued in. The
    /// removal may have taken the very session the queued tunnel was
    /// waiting behind, in which case its turn is now; or the slot may
    /// have gone stale, in which case the hand-off's own guards clear
    /// it. Both answers are better than leaving it: before the status
    /// gate a later reload repainted the orphan `.inactive`, and that
    /// accidental repair is exactly what the gate removed.
    ///
    /// Safe for the unrelated-tunnel case only because the hand-off
    /// tests the slot itself: deleting a bystander while another tunnel
    /// is still up leaves the queue exactly where it was. No-op when the
    /// removed tunnel WAS the queued one, since the slot is cleared
    /// first.
    private func retireFromListAndQueue(_ tunnel: TunnelContainer) {
        if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            tunnels.remove(at: index)
        }
        if waitingTunnel?.id == tunnel.id {
            waitingTunnel = nil
        }
        activateWaitingTunnelIfNeeded()
    }

    /// The uninstall flow's hand on the refresh machinery: from this
    /// call on, no debounced reload runs in this process until the same
    /// flow gives the store back through `releaseStoreAfterUninstall`.
    /// Pair it with a `defer` at the call site: a path that forgets
    /// leaves the list unable to ingest, reconcile or realign until the
    /// gate's own recovery fires, and that recovery only fires when the
    /// extensions come back. See `refreshSuspended` for both doors.
    func suspendRefreshForUninstall() {
        refreshSuspended = true
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    #if DEBUG
    /// Whether a teardown currently holds the store. Readable so a step
    /// can PROVE its arrangement instead of assuming it: a latch that
    /// leaked from an earlier half produces the same green as the
    /// window the step meant to open, and the two must not be confused.
    var isStoreHeldForTeardown: Bool { refreshSuspended }
    #endif

    /// Lowers the latch on behalf of the flow that raised it, which is
    /// the only caller entitled to decide the teardown is over.
    ///
    /// It schedules NOTHING, and that is the load-bearing half. A pass
    /// started here would run against a world the teardown has just
    /// emptied: `ingest` finds no entries and clears the list, and the
    /// restore behind it then reads every payload as one the system
    /// lost and MINTS THEM ALL BACK — the app undoing its own uninstall
    /// about 400ms after reporting it clean. The vault is no wall
    /// either; it answers over its own launchd service for as long as
    /// the extension is resident, and a deactivation that resolves
    /// "will complete after reboot" is the ordinary way to still be
    /// resident here, since a connected tunnel is never stopped by the
    /// disarm sweep.
    ///
    /// Lowering the latch is enough on its own: the list's self-heal is
    /// alive again from this line, and the ordinary triggers — a
    /// configuration change, a return to the foreground — reach it when
    /// there is something to heal.
    func releaseStoreAfterUninstall() {
        refreshSuspended = false
    }

    /// The recovery for a teardown that never came back — and no longer
    /// the one that answers the case it was written for.
    ///
    /// That case was `uninstallAll` suspending on a system approval the
    /// user never answers: the task hung for the life of the process,
    /// the flow's own `defer` never ran, and with ownership in force
    /// nobody else could lower the latch, so the list lived on with
    /// every self-heal dead until relaunch. The wait carries its own
    /// budget now, so it ends and its `defer` runs.
    ///
    /// What is left for this door is what a per-request budget cannot
    /// reach: a latch raised by a task the system tore down some other
    /// way, leaving no exit to run at all. That is an EDGE, and the
    /// pairing must not be misread — a teardown parked on a prompt
    /// leaves the gate sitting at ready without moving, so its trigger
    /// never fires. Neither of the two covers the other; do not delete
    /// one believing it does.
    ///
    /// Gate readiness is the proof that entitles this caller. The
    /// teardown's whole job is to take the extensions DOWN; if they are
    /// reporting ready, no teardown of theirs is in flight, whatever a
    /// stranded continuation still believes.
    func releaseAbandonedStoreLatch() {
        guard refreshSuspended else { return }
        NSLog("[uninstall] the refresh latch outlived its teardown — released on the extensions' return")
        refreshSuspended = false
        scheduleRefresh()
    }

    /// Which store a removal empties first, decided per tunnel by what
    /// its payload turns out to be.
    ///
    /// The two orders fail differently, and the whole choice is about
    /// which residue a half-finished removal leaves. Taking the PAYLOAD
    /// first leaves an entry with no secret: the ownership boundary
    /// reads it as another local user's, so it is invisible to the list,
    /// undeletable through the app, and still armed if it carried a
    /// rule. Taking the ENTRY first leaves a payload with no entry,
    /// which is the shape reconcile exists to repair — the tunnel simply
    /// comes back, whole, and the user deletes it again. Entry-first is
    /// therefore the default: it fails toward "nothing happened".
    ///
    /// The exception is not a preference but a structural fact. An
    /// undecodable payload cannot be restored by anything: `readAll`
    /// returns only what decodes, so reconcile never sees it, and
    /// `ingest` rescues it off its ENTRY — which is exactly why
    /// `removableEntryIds` refuses to let uninstall take that entry
    /// away. Delete such an entry first and then lose the payload
    /// delete, and the secret is locked in the keychain with nothing in
    /// the app able to name it again. For that row the entry is the only
    /// anchor, so the entry goes last.
    ///
    /// A vault that will not answer refuses the removal outright, as a
    /// failed delete always has: better a whole tunnel than a
    /// half-deleted one, and better than guessing an order on evidence
    /// that never arrived.
    ///
    /// This read is a suspension like any other, so the verdict it
    /// returns is a moment old by the time the order runs on it. Nothing
    /// the app writes can change a payload's decodability underneath it
    /// — `modify` is barred for this id by the removal's own latch, and
    /// a store rewrites a decodable payload with another decodable one —
    /// so the only producer would be a write from outside this app,
    /// which is the case the custody surfaces already treat as an
    /// anomaly rather than a state to race.
    private func entryGoesFirst(for tunnel: TunnelContainer) async throws -> Bool {
        // The same patience the delete it replaces at the head of this
        // flow always had. A removal used to open with
        // `delete(id:attempts: 3)`, so a vault that lost one round-trip
        // to a respawn cost the user a retry, not a refusal; asking with
        // a single shot here would have quietly traded that away and
        // turned a transient dark moment into "the tunnel cannot be
        // deleted right now".
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
    /// system store, off a FRESH system list, so no stale provider
    /// object is replayed. Best-effort by design: a survivor is inert
    /// without the extensions, hidden from the list by ingest, and
    /// self-heals on reinstall (payload present — an existing entry is
    /// adopted, a missing one restored by reconcile; both converge).
    ///
    /// The set is NOT recomputed here and cannot be. This runs with the
    /// extensions down, so the vault answers `.unreachable` for every
    /// row, and treating that as removable would take the custody
    /// entries the classification exists to preserve — an unreadable
    /// payload's entry is the only anchor it has. The set's freshness is
    /// therefore bought upstream, by the refresh latch going up BEFORE
    /// the classification and by the reconcile pass re-reading that
    /// latch at each of its writing points.
    ///
    /// Which leaves one honest gap, and it is logged rather than
    /// skipped in silence: an entry in the fresh list that carries an
    /// identity and is not in the set. On a sound run that is another
    /// local user's row, or one of ours whose payload did not decode —
    /// both correctly left alone. But it is also the shape a latch
    /// failure would produce, and a teardown that walks past it without
    /// a word is how "uninstall reported clean" and "there is still an
    /// entry in System Settings" become true at the same time.
    func removeEntriesForUninstall(_ removableIds: Set<UUID>) async {
        guard let providers = try? await providerFactory.loadAllFromPreferences() else {
            NSLog("[uninstall] entry removal skipped — the system list did not load")
            return
        }
        var unclassified = 0
        for provider in providers {
            guard let id = provider.tunnelIdentity?.id else { continue }
            guard removableIds.contains(id) else {
                unclassified += 1
                continue
            }
            do {
                try await provider.removePreferences()
            } catch {
                NSLog("[uninstall] entry removal failed for \(provider.localizedDescription ?? id.uuidString): \(error.localizedDescription)")
            }
        }
        if unclassified > 0 {
            NSLog("[uninstall] \(unclassified) identified entry(ies) were outside the removable set and stay in the system store — another user's, or ours with a payload that does not decode")
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
        // The latch is re-read HERE, and not only at the scheduler.
        // `scheduleRefresh` bars passes that have not started; this bars
        // the one already running, which is a different pass and the
        // dangerous one — the system read above and the ingest behind it
        // are both suspensions, so a teardown can raise the latch after
        // this pass was admitted and before it reaches the line that
        // MINTS. Uninstall classifies its removable set under the latch
        // and then removes exactly that set: an entry minted here would
        // be one the classification never saw, so it survives the
        // teardown and the flow reports clean over it.
        //
        // `ingest` above is deliberately left to finish. It only ever
        // narrows the list to what the system already holds, so it
        // creates nothing for a teardown to miss, and stopping it
        // half-way would leave the mirror describing neither world.
        guard !refreshSuspended else { return }
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
        //
        // Barred by the teardown latch like every other writer on this
        // path, and it belongs in that list even though it starts a
        // SESSION rather than saving an entry: raising a tunnel arms
        // its recovery rule and writes the store to do it, which is
        // precisely what the teardown is trying to empty. Handing the
        // queue on while the extensions are going down would also start
        // a session that has nowhere to run.
        guard !refreshSuspended else { return }
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
    /// create what teardown exists to remove. `remove()` prunes the
    /// mirror by its own hand; the uninstall sweep deliberately does
    /// not — it removes entries under a raised latch and leaves the
    /// mirror to whatever refresh comes next. This stays a harness
    /// surface either way.
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
