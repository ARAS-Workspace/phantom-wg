import Foundation
import Observation
import os.log

/// Whether a verdict is an ANSWER or the absence of one.
///
/// Every verdict that crosses `withRaceTimeout` carries an
/// `.unreachable` case, and the distinction has to reach that method
/// because it decides whether a proven silence may be thrown away — a
/// fast `.unreachable` from an interrupted XPC connection is the
/// strongest proof of silence there is, not a reason to forget one.
///
/// The conformance list is closed by GREP over the helper's call sites,
/// never by a number written here: a count in a comment is the thing
/// this campaign has now caught wrong four times.
///
/// A protocol rather than a closure parameter with a default: a default
/// would let a fifth surface inherit "yes, it spoke" without anyone
/// deciding that, which is exactly how the conflation happened.
protocol VaultAnswerable {
    var isAnswer: Bool { get }
}

/// App-side XPC client for the tunnel extension's secret custody.
///
/// The System keychain is root-owned and this app is a sandboxed user
/// process, so it never touches the vault directly — it asks the
/// extension, which launchd spawns on demand for the Mach service.
/// Every tunnel mutation (import, edit, delete) goes through here, and
/// the read path is what the detail and edit screens use to show a
/// configuration.
///
/// Subclassed twice, and neither subclass is optional to know about
/// when this file changes: the preview support serves the canvas its
/// fixtures without an extension, and the DEBUG harness fabricates
/// custody states no real vault can be asked to produce. Both rely on
/// every RPC below staying non-final and in the class body — an
/// extension cannot be overridden — and on the retry ladders
/// dispatching their single-shot call through `self`, which is what
/// lets a subclass drive the ladder without reimplementing it.
@Observable
@MainActor
class TunnelVaultClient {

    @ObservationIgnored private var connection: NSXPCConnection?
    /// The last usable-payload count the fetchAll line reported, so it
    /// fires on TRANSITIONS rather than on every pass. `nil` means the
    /// next successful answer logs unconditionally — the initial
    /// baseline, and the first light after a dark window.
    @ObservationIgnored private var lastLoggedUsableCount: Int?
    /// How long a proven silence is trusted for. Short on purpose: it
    /// exists to stop a burst of callers each paying the full timeout,
    /// not to decide the extension is gone. Recovery is never delayed
    /// by more than this, and `ping` does not honour it at all.
    private static let darkWindow: TimeInterval = 2
    /// When the last timeout said the extension is not answering, and
    /// how many calls have been spared a full timeout since.
    @ObservationIgnored private var darkUntil: Date?
    @ObservationIgnored private var sparedWhileDark = 0

    @ObservationIgnored private let log = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS",
        category: "vault-client"
    )

    init() {}

    /// The app's own client lives for the process, so this is for the
    /// OTHER kind: an instance a caller owns and drops. `connect()`
    /// resumes an `NSXPCConnection` on first use and nothing else here
    /// ever tears one down, so without this a DEBUG step that builds its
    /// own client leaks a live connection to the vault's Mach service on
    /// every suite run. Harmless for the shared instance, correct for an
    /// owned one — the same shape the raw test client already carries.
    deinit {
        connection?.invalidate()
    }

    // MARK: - Connection lifecycle

    private func connect() {
        guard connection == nil else { return }

        let conn = NSXPCConnection(machServiceName: TunnelVaultService.machServiceName, options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: TunnelVaultDaemonProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
            }
        }
        conn.resume()
        connection = conn
    }

    /// A retry declares the last silence STALE, so the cached verdict
    /// is dropped before the ladder asks again.
    ///
    /// The dark window is for INDEPENDENT callers piling onto a silence
    /// someone else already paid for. A ladder is the opposite act: one
    /// caller spending time on purpose so that it can ask a second time,
    /// and what it is asking is exactly the question the cache cannot
    /// answer — has the extension come back? Reading the window on a
    /// retry collapses all three attempts into the first one's verdict.
    ///
    /// Caught live rather than reasoned about: a removal issued right
    /// after a deactivation, which is the documented respawn race and
    /// the one `entryGoesFirst`'s own doc names, reported "the tunnel
    /// cannot be deleted right now" over a vault that was merely
    /// restarting. The first attempt is still allowed to read the
    /// window — a caller arriving mid-storm should not pay for a
    /// silence just proven — so what a ladder costs at worst is
    /// unchanged from before the window existed.
    ///
    /// The clear is global, which is the honest reading: the ladder has
    /// just declared the cached silence stale, so no other caller
    /// should be answered from it either.
    ///
    /// What that costs is stated exactly, because an earlier version of
    /// this sentence overstated the recovery. The window comes back only
    /// two ways — a TIMEOUT arms it, an ANSWER makes it unnecessary —
    /// and the ladder's own next attempt is guaranteed to be neither. A
    /// fast `.unreachable` from the XPC error handler resolves in
    /// milliseconds, `isAnswer` is false so nothing is cleared, and
    /// nothing arms. That is the canonical respawn shape, so a retrying
    /// ladder can leave the window down until some OTHER caller pays a
    /// full timeout to re-prove the silence. Bounded and deliberate —
    /// the ladder is the one caller whose whole purpose is to re-ask —
    /// but not self-healing, and not to be described as if it were.
    ///
    /// A CANCELLED ladder would not even re-ask, so each call site tests
    /// for cancellation first rather than relying on the loop's own
    /// check, which sits a line too late.
    private func discardProvenSilence() {
        darkUntil = nil
    }

    #if DEBUG
    /// Arms a proven silence by hand, so a step can put a ladder inside
    /// one without taking the extension down.
    ///
    /// The window opens no other way than a real 5-second timeout, and
    /// the only thing that produces one is a vault genuinely away — an
    /// arrangement a step can only reach by deactivating a tunnel and
    /// waiting out a respawn, which would then be measuring the respawn
    /// rather than the ladder. The live proof that the collapse was
    /// real is elsewhere and stays there: it is the removal a run makes
    /// right after an abort.
    func armProvenSilenceForTesting() {
        darkUntil = Date().addingTimeInterval(Self.darkWindow)
    }

    /// Whether a proven silence is standing right now. A step that arms
    /// one and then runs a ladder reads this after: a ladder that read
    /// the window on its retries would have left it up and answered
    /// from it.
    var hasProvenSilence: Bool {
        guard let darkUntil else { return false }
        return Date() < darkUntil
    }

    /// Every call the window has ever answered, monotonically.
    ///
    /// This is what lets a step judge the ladder by COUNT rather than by
    /// wall clock. Under an armed window a ladder that discards the
    /// silence spares exactly its first attempt and really asks the
    /// second; one that honours the window on every retry spares all
    /// three. One versus three is a reading no slow machine and no slow
    /// vault can blur, which a duration threshold cannot say.
    ///
    /// It has to be its OWN counter, and that was measured rather than
    /// reasoned: `sparedWhileDark` belongs to the log line and means
    /// "since the last timeout", so a real answer zeroes it — and a real
    /// answer is precisely what a ladder produces on its way out. A step
    /// reading that one after the ladder read 0 whatever had happened,
    /// which is how the first version of this witness failed twice while
    /// the product was doing exactly the right thing.
    private(set) var darkWindowAnswersTotal = 0
    #endif

    private func proxy(
        _ onError: @escaping @Sendable (Error) -> Void
    ) -> TunnelVaultDaemonProtocol? {
        if connection == nil { connect() }
        guard let conn = connection else { return nil }
        return conn.remoteObjectProxyWithErrorHandler(onError) as? TunnelVaultDaemonProtocol
    }

    // MARK: - RPCs

    /// Outcome of a single write. The old Bool collapsed two different
    /// stories into one `false`, and every call site paid for it with
    /// a verified-sounding claim over a reading that verified nothing:
    /// `.refused` is the daemon ANSWERING no — definitive, the state
    /// stands as it was — while `.unreachable` is no answer at all,
    /// where the write may even have LANDED with only its reply lost.
    /// Callers that report state must branch on the difference; a
    /// caller that only needs success compares `== .done`.
    enum Write: Equatable, VaultAnswerable {
        case done
        case refused
        case unreachable

        var label: String {
            switch self {
            case .done: return "done"
            case .refused: return "refused"
            case .unreachable: return "unreachable"
            }
        }

        /// A refusal is speech: the daemon was reached and said no.
        var isAnswer: Bool { self != .unreachable }
    }

    /// Hands a tunnel's configuration to the extension for custody.
    /// An encode failure is a local, definitive no and answers
    /// `.refused`; transport-level silence answers `.unreachable`.
    @discardableResult
    func store(_ config: TunnelConfig) async -> Write {
        guard let payload = try? JSONEncoder().encode(config) else {
            os_log("store — encode FAILED", log: log, type: .error)
            return .refused
        }
        let id = config.id.uuidString

        return await withRaceTimeout("store", seconds: 5, fallback: .unreachable) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Write, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("store error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(.unreachable)
                }) else {
                    resume.finish(.unreachable)
                    return
                }
                proxy.storeVault(payload, id: id) { ok in resume.finish(ok ? .done : .refused) }
            }
        }
    }

    /// Stores with the same patience `read(id:attempts:)` gives reads.
    /// The vault listener lives in the tunnel extension process, so a
    /// mutation issued right after a tunnel deactivation can lose the
    /// teardown/respawn race on its first try — caught live by the
    /// in-app test engine (an import right after a deactivation failed
    /// its one-shot store). Both non-done outcomes are retried — a
    /// store is an idempotent upsert, so retrying a refusal is
    /// harmless and a respawn-window keychain door can open between
    /// attempts — and the LAST outcome is returned, typed, so the
    /// caller still learns how the final attempt ended. A cancelled
    /// task sends nothing further and answers the last completed
    /// attempt's outcome — `.unreachable` when nothing was sent.
    @discardableResult
    func store(_ config: TunnelConfig, attempts: Int) async -> Write {
        var outcome = Write.unreachable
        for attempt in 1...max(1, attempts) {
            if Task.isCancelled { return outcome }
            outcome = await store(config)
            if outcome == .done { return outcome }
            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(600 * attempt))
                // Only a ladder that is going to ASK may declare the
                // silence stale. `try?` swallows the cancellation a
                // cancelled sleep throws, so without this test a ladder
                // whose caller walked away — the detail and edit screens
                // both run theirs in a `.task` — would clear the window
                // on its way out, re-exposing every other caller to the
                // storm it had just been spared with nothing left to
                // re-arm it.
                if Task.isCancelled { return outcome }
                discardProvenSilence()
            }
        }
        return outcome
    }

    /// Outcome of a single read. The two failures are different
    /// stories and callers must not tell them the same way: the vault
    /// answering "no such payload" is final, while failing to reach
    /// the vault at all is usually a moment old — the extension is
    /// spawned on demand, and the first connection after it has been
    /// idle can lose the race.
    enum Read {
        case config(TunnelConfig)
        /// The vault answered and holds no payload for this id — or
        /// none this user owns: the daemon serves another account's
        /// item as absence, so this is also the foreign verdict.
        case missing
        /// The vault holds a payload for this id, but it does not
        /// decode into a `TunnelConfig`. Distinct from `.missing` on
        /// purpose: `.missing` is the ownership verdict — not this
        /// user's — while this secret is present, just unreadable, so
        /// ingest must keep the row listed and uninstall must keep
        /// its entry. A custody problem to surface, not an absence to
        /// act on.
        case undecodable
        /// The vault could not be reached, did not answer in time, or
        /// answered that it could not look.
        case unreachable
    }

    /// One attempt, and the one the ladders call: overriding this
    /// method alone is what lets a subclass answer for every retrying
    /// caller too.
    func read(id: UUID) async -> Read {
        let key = id.uuidString

        let raw: RawRead = await withRaceTimeout("fetch", seconds: 5, fallback: .unreachable) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<RawRead, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("fetch error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(.unreachable)
                }) else {
                    resume.finish(.unreachable)
                    return
                }
                proxy.fetchVault(id: key) { data, ok in
                    guard ok else {
                        resume.finish(.failed)
                        return
                    }
                    resume.finish(data.map(RawRead.payload) ?? .empty)
                }
            }
        }

        switch raw {
        case .unreachable:
            return .unreachable
        case .failed:
            os_log("fetch — the vault answered but could not read %{public}@",
                   log: log, type: .error, key)
            return .unreachable
        case .empty:
            os_log("fetch — vault holds no payload for %{public}@", log: log, type: .default, key)
            return .missing
        case .payload(let data):
            guard let config = try? JSONDecoder().decode(TunnelConfig.self, from: data) else {
                os_log("fetch — payload for %{public}@ FAILED to decode (present but unreadable)", log: log, type: .error, key)
                return .undecodable
            }
            return .config(config)
        }
    }

    /// Reads, retrying only what is worth retrying. A vault that
    /// answers "missing" is believed the first time; one that cannot
    /// be reached is given a few more chances, spaced out, because
    /// waking the extension is what usually costs the first attempt.
    /// `onAttempt` reports each try so a view can show its progress,
    /// and cancelling the caller's task stops the loop — leaving the
    /// screen ends the retries with it.
    func read(
        id: UUID,
        attempts: Int,
        onAttempt: @MainActor @escaping (Int) -> Void = { _ in }
    ) async -> Read {
        var result = Read.unreachable

        for attempt in 1...max(1, attempts) {
            if Task.isCancelled { return result }
            onAttempt(attempt)

            result = await read(id: id)
            if case .unreachable = result {} else { return result }

            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(600 * attempt))
                // Only a ladder that is going to ASK may declare the
                // silence stale. `try?` swallows the cancellation a
                // cancelled sleep throws, so without this test a ladder
                // whose caller walked away — the detail and edit screens
                // both run theirs in a `.task` — would clear the window
                // on its way out, re-exposing every other caller to the
                // storm it had just been spared with nothing left to
                // re-arm it.
                if Task.isCancelled { return result }
                discardProvenSilence()
            }
        }

        return result
    }

    /// Deleting an absent id answers `.done` (idempotent); `.refused`
    /// is the daemon answering that the keychain would not give the
    /// item up, `.unreachable` is silence — where the delete may have
    /// landed with only its reply lost.
    @discardableResult
    func delete(id: UUID) async -> Write {
        let key = id.uuidString

        return await withRaceTimeout("delete", seconds: 5, fallback: .unreachable) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Write, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("delete error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(.unreachable)
                }) else {
                    resume.finish(.unreachable)
                    return
                }
                proxy.deleteVault(id: key) { ok in resume.finish(ok ? .done : .refused) }
            }
        }
    }

    /// Delete-by-id is idempotent the same way — see `store(_:attempts:)`
    /// for the retry-and-return-last contract.
    @discardableResult
    func delete(id: UUID, attempts: Int) async -> Write {
        var outcome = Write.unreachable
        for attempt in 1...max(1, attempts) {
            if Task.isCancelled { return outcome }
            outcome = await delete(id: id)
            if outcome == .done { return outcome }
            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(600 * attempt))
                // Only a ladder that is going to ASK may declare the
                // silence stale. `try?` swallows the cancellation a
                // cancelled sleep throws, so without this test a ladder
                // whose caller walked away — the detail and edit screens
                // both run theirs in a `.task` — would clear the window
                // on its way out, re-exposing every other caller to the
                // storm it had just been spared with nothing left to
                // re-arm it.
                if Task.isCancelled { return outcome }
                discardProvenSilence()
            }
        }
        return outcome
    }

    /// Outcome of the session probe. Three stories the gate tells
    /// apart: the extension answering with a closed vault door is not
    /// the extension being asleep. Both answered arms carry the
    /// extension's build identity — an answer proves liveness whatever
    /// the door says, and the extension gate reads the identity off
    /// the same probe the vault session uses.
    enum Ping: VaultAnswerable {
        case ready(payloads: Int, identity: String)
        /// The extension answered; the System keychain did not.
        case doorFailed(identity: String)
        /// No answer at all — the extension is not awake (yet).
        case unreachable

        /// A closed keychain door is still the extension answering.
        var isAnswer: Bool { if case .unreachable = self { false } else { true } }
    }

    /// Session probe — wakes the extension through launchd if needed
    /// and proves the custody chain end to end. Single attempt;
    /// patience lives in `TunnelVaultSession`.
    func ping() async -> Ping {
        await withRaceTimeout("ping", seconds: 5, fallback: .unreachable, honouringDarkWindow: false) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Ping, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("ping error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(.unreachable)
                }) else {
                    resume.finish(.unreachable)
                    return
                }
                proxy.pingIdentity { identity, ready, count in
                    resume.finish(ready
                        ? .ready(payloads: count, identity: identity)
                        : .doorFailed(identity: identity))
                }
            }
        }
    }

    /// Outcome of reading the whole vault. As with a single read the
    /// two outcomes must stay apart, and here it matters far more: an
    /// empty answer means the vault owns nothing, while an unreachable
    /// or failing vault means we know nothing at all. The decoded set
    /// is the ownership evidence everything downstream scopes by —
    /// the ingest boundary, the slot classifier, reconcile's restores
    /// — and evidence that never arrived must not impersonate "this
    /// user owns nothing".
    enum ReadAll {
        case configs([TunnelConfig])
        case unreachable
    }

    /// Every configuration the vault holds for this user. The vault
    /// outlives the system's NetworkExtension preferences — macOS
    /// drops a tunnel's configuration when its provider extension is
    /// uninstalled — so this is what reconcile compares against.
    func readAll() async -> ReadAll {
        let raw: RawReadAll = await withRaceTimeout("fetchAll", seconds: 5, fallback: .unreachable) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<RawReadAll, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("fetchAll error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(.unreachable)
                }) else {
                    resume.finish(.unreachable)
                    return
                }
                // An empty vault answers `[]`. `nil` is the vault
                // saying it could not enumerate — the daemon spoke,
                // but taught nothing.
                proxy.fetchAllVaults { data in
                    resume.finish(data.map(RawReadAll.payloads) ?? .failed)
                }
            }
        }

        let payloads: [Data]
        switch raw {
        case .payloads(let answered):
            payloads = answered
        case .failed:
            os_log("fetchAll — the vault answered but could not enumerate",
                   log: log, type: .error)
            lastLoggedUsableCount = nil
            return .unreachable
        case .unreachable:
            lastLoggedUsableCount = nil
            return .unreachable
        }

        // A payload only counts once it decodes — that is the gate for
        // recreating anything. Undecodable ones are reported rather
        // than dropped in silence: they still occupy the vault, and a
        // sudden count is the signal that a schema moved underneath us.
        var configs: [TunnelConfig] = []
        var undecodable = 0
        for payload in payloads {
            if let config = try? JSONDecoder().decode(TunnelConfig.self, from: payload) {
                configs.append(config)
            } else {
                undecodable += 1
            }
        }

        // The steady state stays quiet. This funnel runs on every
        // refresh, verdict and reconcile pass, so an unchanged count
        // repeated is noise carrying nothing; the count's diagnostic
        // value — the custody and isolation field signal — lives in
        // its TRANSITIONS. So the line fires when the count moves,
        // once for the initial baseline, and again on the first
        // answer after a dark window (the reset above), while every
        // failure path keeps its own line unconditionally.
        if configs.count != lastLoggedUsableCount {
            os_log("fetchAll — %{public}d usable payload(s)", log: log, type: .default, configs.count)
            lastLoggedUsableCount = configs.count
        }
        if undecodable > 0 {
            os_log("fetchAll — %{public}d payload(s) FAILED to decode and were ignored",
                   log: log, type: .error, undecodable)
        }
        return .configs(configs)
    }

    // MARK: - Race-Timeout Helper

    /// Race an async operation against a sleep; first to finish wins.
    /// The losing side keeps running — `NSXPCConnection` RPCs aren't
    /// cancellable from Swift — but its eventual result is dropped.
    /// A timeout win is logged: without that line an extension that
    /// never answers is indistinguishable from an empty vault.
    ///
    /// There are TWO exits, and only one of them races. A caller that
    /// honours the dark window and arrives while a silence is still
    /// proven takes the fallback immediately, spending no round-trip
    /// and printing nothing — so the log is not a call counter and must
    /// not be read as one. Those spared calls are counted instead, and
    /// the count rides out on the NEXT TIMEOUT — so it is reported only
    /// when the silence PERSISTS. An answer clears the window and zeroes
    /// the counter without printing anything, which means the case where
    /// the window did its job and recovery arrived is exactly the case
    /// the field never sees a number for. Said here rather than left to
    /// be discovered: this log under-reports by construction, and a step
    /// that needs the real figure reads the DEBUG total instead.
    private func withRaceTimeout<T: Sendable & VaultAnswerable>(
        _ label: String,
        seconds: Double,
        fallback: T,
        honouringDarkWindow: Bool = true,
        operation: @escaping @MainActor () async -> T
    ) async -> T {
        // A silence already proven, reused instead of re-bought. When
        // the extension respawns, three independent callers keep asking
        // on their own cadences and each pays the full timeout — the
        // field logs show that as twenty-five consecutive stalls in one
        // window, which is not diagnosis, it is the same fact printed
        // twenty-five times while the app freezes its vault surface for
        // two minutes of wall clock.
        //
        // What this is NOT: a decision that the vault is gone. The
        // verdict handed back is the same one a full timeout would have
        // produced, so no caller learns anything it would not have
        // learned — but "nothing downstream changes" would be too
        // strong, and an earlier version of this comment said it.
        // `.unreachable` IS acted on: `ownedProviders` holds back every
        // provider it cannot verify (TunnelsManager's cached-keep rule)
        // and the per-id form short-circuits the rest of that pass. The
        // honest bound is therefore about TIME, not about consequence —
        // recovery stays invisible for up to `darkWindow` after a proven
        // silence, and rows stay held back for exactly that long. The
        // window is short for that reason, and `ping` does not READ it
        // — which is not the same as opting out. A ping timeout still
        // proves a silence and arms the window for everyone else, and a
        // ping answer still clears it. Only the reading is skipped, and
        // that is the point: probing is how recovery is discovered, so
        // the probe must never be answered from a cache.
        //
        // What it also is not, and what an earlier version of this
        // comment claimed it was: harmless to a caller that RETRIES.
        // "Every caller gets the same verdict, just sooner" is true of
        // a single-shot caller and false of a ladder, whose later
        // attempts are not re-buying a proven silence but asking
        // whether the respawn that caused it has finished. The three
        // ladders sleep 600ms then 1200ms — 1.8s against this 2s
        // window — so a ladder that began inside one never reached the
        // extension at all, and the patience every CRUD path is
        // promised became a single shot taken at the worst possible
        // moment. `discardProvenSilence()` is what keeps that from
        // happening; the sentence above is left standing as a record of
        // how a comfortable claim about a cache read as a guarantee.
        if honouringDarkWindow, let darkUntil, Date() < darkUntil {
            sparedWhileDark += 1
            #if DEBUG
            darkWindowAnswersTotal += 1
            #endif
            return fallback
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let resume = SingleResume(continuation)
            Task { @MainActor in
                let result = await operation()
                // Winning the race is not the same as SPEAKING, and
                // conflating them defeated the window with the calls
                // that prove a silence hardest. Every RPC below resolves
                // its own continuation with `.unreachable` from the XPC
                // error handler, and an interrupted or invalidated
                // connection is the canonical proof that the extension
                // is absent — yet it resolves in milliseconds, so it
                // beats the timeout, and clearing the window on it threw
                // away a silence a full five seconds had just bought.
                // The question is asked of the VERDICT rather than of
                // this method, because only a verdict knows which of its
                // own cases mean "no answer at all" — and it is a
                // protocol requirement rather than a defaulted closure so
                // that a surface added later has to answer it instead of
                // inheriting a wrong yes.
                if resume.finish(result), result.isAnswer {
                    self.darkUntil = nil
                    self.sparedWhileDark = 0
                }
            }
            Task { @MainActor [log] in
                try? await Task.sleep(for: .seconds(seconds))
                guard resume.finish(fallback) else { return }
                let spared = self.sparedWhileDark
                self.darkUntil = Date().addingTimeInterval(Self.darkWindow)
                self.sparedWhileDark = 0
                if spared > 0 {
                    os_log("""
                           %{public}@ TIMED OUT after %{public}.0fs — extension unreachable \
                           (%{public}d call(s) answered from the dark window since the last timeout)
                           """,
                           log: log, type: .error, label, seconds, spared)
                } else {
                    os_log("%{public}@ TIMED OUT after %{public}.0fs — extension unreachable",
                           log: log, type: .error, label, seconds)
                }
            }
        }
    }
}

/// What came back over the wire, before it is interpreted. Absence
/// and failure stay apart the whole way down: an answered "nothing
/// here" is a fact, while a vault that answered "could not look"
/// teaches as little as one that never spoke.
private enum RawRead: VaultAnswerable {
    case payload(Data)
    case empty
    case failed
    case unreachable

    var isAnswer: Bool { if case .unreachable = self { false } else { true } }
}

/// Same distinction for the bulk read: an answered-but-empty vault is
/// a fact, a failed or silent one is an absence of facts.
private enum RawReadAll: VaultAnswerable {
    case payloads([Data])
    case failed
    case unreachable

    var isAnswer: Bool { if case .unreachable = self { false } else { true } }
}

// The one-shot continuation guard these races ride lives in
// Infrastructure/Concurrency/SingleResume.swift — shared with the
// tunnels manager's deadline helper and the DEBUG harness.
