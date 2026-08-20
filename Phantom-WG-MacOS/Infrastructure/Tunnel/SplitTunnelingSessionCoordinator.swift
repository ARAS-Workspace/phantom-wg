import Foundation
import Observation
import os.log

/// Single source of truth for the Split-Tunneling feature's runtime
/// state. The UI toggle binds to `state.isUserVisiblyActive`; the
/// coordinator drives both managers in lockstep at the preference
/// layer and pushes live config updates to both extensions over
/// their `ProxyConfigDaemon` XPC channels (`applyConfig`). The two
/// extensions run independently — they do not monitor or coordinate
/// with each other.
@Observable
@MainActor
final class SplitTunnelingSessionCoordinator {

    enum State: Equatable {
        case stopped
        case starting
        case running
        case stopping

        var isUserVisiblyActive: Bool {
            switch self {
            case .running, .starting: return true
            case .stopped, .stopping: return false
            }
        }
    }

    private(set) var state: State = .stopped

    /// Tail of the lifecycle chain. Every public entry point links onto
    /// it, so two transitions can never interleave — the guards alone
    /// could not stop that: `start` accepted `.stopping` and `stop`
    /// accepted `.starting`, and each one's first `await` handed the
    /// actor over to the other, both of them writing the same
    /// `NEDNSProxyManager.shared()`.
    ///
    /// Serialized rather than rejected, unlike the extension gate's
    /// second-press rule, because these come from a toggle: the user's
    /// LAST intent has to be the one that stands, and refusing it would
    /// leave the screen describing a session nobody asked for.
    ///
    /// The link is captured BEFORE the new task is stored. Assigning
    /// first and reading after would make every task await ITSELF and
    /// the feature would hang on its first press.
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    /// Which link registered the tail last. `Task` is a value type, so
    /// there is no identity to compare — a generation is how a link
    /// knows whether it is still the tail and may therefore clear it.
    @ObservationIgnored private var chainGeneration = 0

    /// Links waiting for their turn, observed.
    ///
    /// `state` cannot answer this: a queued link has not run a line of
    /// its operation yet, so nothing has moved off `.running` or
    /// `.stopped`. Without this the toggle sprang back the moment it was
    /// pressed — the user's intent was accepted and queued while the
    /// screen still showed the old position, which reads as a control
    /// that ignored them.
    private(set) var queuedLinks = 0

    /// The most links this chain has ever held at once, recorded WHERE
    /// IT HAPPENS rather than sampled from outside.
    ///
    /// A step that polled `queuedLinks` on a timer measured zero against
    /// a chain that was demonstrably serializing — the queued window was
    /// narrower than the sampling interval, so the gauge was right and
    /// the reading missed it. A high-water mark cannot be missed: the
    /// link that queues is the one that writes it.
    ///
    /// What it counts is a link that had to WAIT for a predecessor still
    /// in flight. It used to overcount, because the tail was never
    /// released and a finished predecessor still made its successor
    /// register as queued.
    private(set) var maxChainDepth = 0

    /// Where a chained `performStart` leaves its error. It cannot be
    /// thrown out of the chain directly, and it lives one hop instead of
    /// being swallowed, because `start` is `throws` and its callers
    /// decide what to do with a failure.
    @ObservationIgnored private var chainedStartError: Error?

    /// How long a link may wait on the one before it.
    ///
    /// The chain needs a ceiling because neither `enable` nor `disable`
    /// has one: `saveToPreferences` raises the system's proxy-permission
    /// prompt and its completion arrives when the user answers, so an
    /// unanswered dialog suspends a link indefinitely. Without a ceiling
    /// the queue behind it includes `purgeForUninstall`, and an uninstall
    /// held hostage by a dialog nobody answered is a worse ending than
    /// the interleaving this chain exists to prevent.
    ///
    /// So the ceiling proceeds rather than fails: after it, the waiting
    /// link runs anyway and says so. That is today's behaviour restored
    /// for the one case where something has already been stuck for a
    /// minute — not a new hazard, just the old one no longer able to
    /// take the app with it. How that is made to actually happen is in
    /// `waitForPredecessor`, and the first version of it did not.
    ///
    /// Sixty seconds is the gate's `deactivationBudget`, deliberately
    /// the same number for the same reason: it is what this app is
    /// willing to spend on an unanswered dialog. Per instance rather
    /// than a type constant, so a step proving the ceiling ENDS a wait
    /// can shorten it instead of sitting for a minute.
    @ObservationIgnored private let chainCeiling: Duration

    /// Waits for the previous link, but never longer than the ceiling.
    ///
    /// Shaped like the vault and proxy clients' `withRaceTimeout` for a
    /// reason the first attempt at this got wrong: it used a task group,
    /// and a task group AWAITS its remaining children before its body's
    /// result comes back. The losing child was `await predecessor.value`
    /// on a `Task<Void, Never>` — non-throwing, so it ignores
    /// cancellation entirely and `cancelAll()` could not end it. The
    /// group therefore returned only once the predecessor finished, and
    /// the ceiling changed nothing but the log line, under a comment
    /// claiming an unanswered dialog could no longer hold an uninstall.
    ///
    /// Two UNSTRUCTURED tasks race a one-shot resume instead. The loser
    /// keeps running and its result is dropped, exactly as the sibling
    /// helpers document for RPCs Swift cannot cancel — and because
    /// nothing awaits the loser, the wait is bounded by construction.
    private static func waitForPredecessor(
        _ predecessor: Task<Void, Never>,
        upTo ceiling: Duration
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resume = SingleResume(continuation)
            Task {
                await predecessor.value
                resume.finish(true)
            }
            Task {
                try? await Task.sleep(for: ceiling)
                resume.finish(false)
            }
        }
    }

    private func serialized(_ operation: @MainActor @escaping () async -> Void) async {
        let predecessor = inFlight
        let ceiling = chainCeiling
        let task = Task { @MainActor in
            if let predecessor {
                self.queuedLinks += 1
                self.maxChainDepth = max(self.maxChainDepth, self.queuedLinks + 1)
                defer { self.queuedLinks -= 1 }
                let landed = await Self.waitForPredecessor(predecessor, upTo: ceiling)
                if !landed {
                    self.log("chain: predecessor outlived its ceiling — proceeding anyway")
                }
            }
            await operation()
        }
        chainGeneration += 1
        let generation = chainGeneration
        inFlight = task
        await task.value
        // Released once it is done, and that is not housekeeping. Left
        // set, a COMPLETED predecessor still made the next call count
        // itself as queued — the depth this publishes was inflated by
        // one for every link after the first, and the run reported
        // "2 → 3" for two dispatched operations. It also means a lone
        // call no longer starts a ceiling sleeper it has nothing to
        // wait for.
        if chainGeneration == generation { inFlight = nil }
    }

    @ObservationIgnored private let split: SplitTunnelProviderManager
    @ObservationIgnored private let dns: DNSProxyProviderManager
    @ObservationIgnored private let dnsDaemonClient: DNSProxyDaemonClient
    @ObservationIgnored private let splitDaemonClient: SplitTunnelDaemonClient
    @ObservationIgnored private let oslog = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS",
        category: "session-coordinator"
    )

    /// Production leaves `state` at `.stopped` and lets `boot(freshConfig:)`
    /// reconcile against the live extensions; previews pass a fixed
    /// state to render the feature mid-session.
    init(
        split: SplitTunnelProviderManager,
        dns: DNSProxyProviderManager,
        dnsDaemonClient: DNSProxyDaemonClient,
        splitDaemonClient: SplitTunnelDaemonClient,
        state: State = .stopped,
        chainCeiling: Duration = .seconds(60)
    ) {
        self.chainCeiling = chainCeiling
        self.split = split
        self.dns = dns
        self.dnsDaemonClient = dnsDaemonClient
        self.splitDaemonClient = splitDaemonClient
        self.state = state
    }

    // MARK: - Boot Reconcile

    /// Called once after the extension gate clears. Adopts the live
    /// session status; honors `config.isEnabled` only when nothing is
    /// running.
    /// `freshConfig` is read AFTER the two loads rather than captured
    /// before them. The loads are real awaits, and an edit accepted in
    /// that window reaches disk while `reconfigure` refuses it — the
    /// state is not `.running` yet — so pushing the snapshot this
    /// method started with would hand both extensions the list the
    /// user just changed away from, and the realign would author the
    /// divergence it runs to repair.
    @discardableResult
    func boot(freshConfig: @MainActor @escaping () -> SplitTunnelingConfiguration) async -> ReconfigureOutcome {
        var outcome = ReconfigureOutcome.notRunning
        let snapshot = freshConfig()
        await serialized { [weak self] in
            outcome = await self?.performBoot(booted: snapshot, freshConfig: freshConfig) ?? .notRunning
        }
        return outcome
    }

    private func performBoot(
        booted: SplitTunnelingConfiguration,
        freshConfig: @MainActor @escaping () -> SplitTunnelingConfiguration
    ) async -> ReconfigureOutcome {
        // Labelled "at entry" because that is what it is: `booted` is the
        // snapshot taken before the chain, and the arm below decides on
        // `config`, re-read after both `load()` awaits. An edit accepted in
        // that window makes this line and the decision disagree.
        log("boot: start (persisted intent at entry isEnabled=\(booted.isEnabled), may be superseded after loads)")
        await split.load()
        await dns.load()
        let config = freshConfig()
        let splitStatus = split.sessionStatus
        log("boot: split.sessionStatus=\(splitStatus)")

        switch splitStatus {
        case .connected, .connecting:
            log("boot: SplitTunnel session already live → adopting .running")
            // The adopted session may be running a list this app never
            // sent it. Until this arm existed the blob had two writers
            // — `enable`, called only from `start`, and
            // `persistConfiguration`, called only from `reconfigure` on
            // a user edit — so an extension that respawned after the
            // last of those came up with whatever was current at THAT
            // moment, and nothing repaired it. On a machine nobody
            // edits, the divergence lasted forever. The call thirty
            // lines below is the third writer, and it is here precisely
            // so a respawn no longer has the last word.
            //
            // Deliberately NOT `reconfigure`: that also persists the
            // DNS `providerConfiguration`, and a boot has no business
            // writing to the preference layer just to read it back.
            // Pushed BEFORE `state = .running` on purpose. Adopting
            // first would open a window where `reconfigure` passes its
            // `.running` guard and races these two writes over the same
            // two daemons — a repair arm that produces the divergence
            // it exists to close.
            let splitPush = await splitDaemonClient.applyConfig(config)
            let dnsRealign = await dnsDaemonClient.applyConfig(config)
            log("boot: realign push → SplitTunnel \(splitPush.label), DNSProxy \(dnsRealign.label)")

            // The two pushes above repair the RUNNING processes; this
            // repairs the DISK. Without it the arm fixed the divergence
            // only until the next respawn, because a respawn reads the
            // blob and nothing else — and every user upgrading from
            // v2.1.1 arrives with a blob frozen at their last `start`,
            // which is the exact defect `reconfigure` was taught to
            // avoid for edits. `persistConfiguration` is the one-sided
            // writer: it does not touch DNS, so the objection above
            // does not reach it; it reads `isEnabled` off disk and
            // refuses a disabled entry; and it skips the write entirely
            // when the blob already matches, so a machine that is
            // already aligned pays nothing.
            do {
                try await split.persistConfiguration(config)
                log("boot: SplitTunnel bootstrap blob realigned")
            } catch {
                log("boot: SplitTunnel bootstrap blob NOT realigned — \(error.localizedDescription)")
            }
            state = .running
            // Reported, not just logged. A realign that did not land is
            // the same class `Push` was introduced for: the extensions
            // keep running the list from the last `start`, and ending
            // in os_log would be exactly the silence this campaign
            // removed everywhere else.
            return .pushed(split: splitPush, dns: dnsRealign)
        case .disconnected, .disconnecting, .invalid:
            if config.isEnabled {
                log("boot: persisted intent ON, no live session → start()")
                // `performStart`, not `start`: this already holds the
                // chain link and re-entering it would deadlock.
                try? await performStart(with: config)
            } else {
                log("boot: persisted intent OFF → state = .stopped")
                state = .stopped
            }
            // Neither arm pushed: `start` carries the payload through
            // `enable`, and the OFF arm has nothing to deliver.
            return .notRunning
        }
    }

    // MARK: - Lifecycle

    /// Master toggle ON. Both managers register; SplitTunnel session
    /// starts via `startVPNTunnel`. DNSProxy stays "registered but
    /// lazy" — the OS spawns it when SplitTunnel routes a port-53
    /// flow to it. Failure rolls back to `.stopped`.
    func start(with config: SplitTunnelingConfiguration) async throws {
        chainedStartError = nil
        await serialized { [weak self] in
            guard let self else { return }
            do { try await self.performStart(with: config) } catch { self.chainedStartError = error }
        }
        if let error = chainedStartError {
            chainedStartError = nil
            throw error
        }
    }

    private func performStart(with config: SplitTunnelingConfiguration) async throws {
        switch state {
        case .running, .starting:
            log("start: already \(state) — no-op")
            return
        case .stopped, .stopping:
            break
        }
        log("start: enabling extensions (apps=\(config.apps.count), iface=\(config.interfaceSelection))")
        state = .starting
        do {
            try await dns.enable(with: config)
            log("start: DNSProxy registered")
            try await split.enable(with: config)
            log("start: SplitTunnel registered + tunnel started")
            state = .running
            log("start: state = .running")
        } catch {
            log("start: failed — \(error.localizedDescription); rolling back")
            state = .stopping
            // Both results are read. `dns.enable` runs FIRST, so a start
            // that fails on the split half has already registered
            // DNSProxy — and this run proved the rollback's own save can
            // be refused by the same class that broke the start
            // (`NEConfigurationErrorDomain Code=10`). Announcing
            // `.stopped` over two swallowed refusals would leave DNSProxy
            // enabled on its own: a listed app's DNS going to the
            // physical resolver while its data stays in the tunnel,
            // which is the asymmetry this architecture exists to
            // prevent, and nothing anywhere would say so.
            var rolled: [String] = []
            do {
                try await split.disable()
                rolled.append("SplitTunnel down")
            } catch {
                rolled.append("SplitTunnel STILL UP (\(error.localizedDescription))")
            }
            do {
                try await dns.disable()
                rolled.append("DNSProxy down")
            } catch {
                rolled.append("DNSProxy STILL REGISTERED (\(error.localizedDescription))")
            }
            state = .stopped
            log("start: rollback → \(rolled.joined(separator: ", ")); state = .stopped")
            throw error
        }
    }

    /// Master toggle OFF. SplitTunnel stops first so the port-53
    /// carve-out is gone before DNSProxy unwinds.
    @discardableResult
    func stop() async -> StopOutcome {
        // `.alreadyStopped` rather than `.landed` on both fallbacks, and
        // for the reason the case exists: a coordinator that went away
        // before the chain reached it asked NOTHING of either extension,
        // and `.landed` is a claim that both came down. Defaulting to it
        // reopened, through a second door, the class `.alreadyStopped`
        // was introduced to close — `recordStop` would have cleared a
        // residue row naming an entry still registered.
        var outcome = StopOutcome.alreadyStopped
        await serialized { [weak self] in
            outcome = await self?.performStop() ?? .alreadyStopped
        }
        return outcome
    }

    private func performStop() async -> StopOutcome {
        switch state {
        case .stopped, .stopping:
            log("stop: already \(state) — no-op")
            return .alreadyStopped
        case .running, .starting:
            break
        }
        log("stop: disabling extensions")
        state = .stopping
        // Both results are read, the same way the start rollback reads
        // them. Announcing `.stopped` over two swallowed refusals is the
        // asymmetry this architecture exists to prevent, in its worst
        // direction: DNSProxy registered alone relays the machine's DNS
        // while the screen says the feature is off, so a listed app's
        // data leaves through the tunnel and its lookups do not. The old
        // shape could not even see it — both calls were `try?` and both
        // log lines were unconditional.
        var residue: [String] = []
        do {
            try await split.disable()
            log("stop: SplitTunnel disabled")
        } catch {
            residue.append("SplitTunnel")
            log("stop: SplitTunnel STILL REGISTERED — \(error.localizedDescription)")
        }
        do {
            try await dns.disable()
            log("stop: DNSProxy disabled")
        } catch {
            residue.append("DNSProxy")
            log("stop: DNSProxy STILL REGISTERED — \(error.localizedDescription)")
        }
        state = .stopped
        log("stop: state = .stopped")
        return residue.isEmpty ? .landed : .residue(residue)
    }

    // MARK: - Uninstall

    /// Uninstall-path cleanup: stops a running session, then deletes
    /// both proxy preference entries. Best-effort by design — a
    /// survivor is inert without its extension, and the next enable
    /// replaces it wholesale.
    func purgeForUninstall() async {
        // One link for the whole teardown, and `performStop` rather
        // than `stop`: a chained call that re-entered the chain would
        // await the link it is already holding and never return.
        await serialized { [weak self] in
            guard let self else { return }
            // Discarded on purpose, and this is the one caller entitled
            // to: the two `remove()` calls below delete the preference
            // entries outright, so an entry that refused to go disabled
            // is about to stop existing. Reporting a residue the next
            // line erases would be noise.
            _ = await self.performStop()
            await self.split.remove()
            await self.dns.remove()
            // "requested", not "removed": both `remove()` calls above
            // return Void and swallow their own save with `try?`, and both
            // document themselves as best-effort. This line announced a
            // deletion it cannot know happened — the same shape this
            // campaign closed for "SplitTunnel down" in the rollback.
            self.log("purgeForUninstall: proxy preference entry removal requested (best-effort)")
        }
    }

    /// What a stop left behind, named.
    ///
    /// A `Bool` here would repeat the mistake `Push` was introduced to
    /// end: "the stop did not fully land" and "DNSProxy is still
    /// registered while the screen says the feature is off" are not the
    /// same sentence, and only the second one tells the user what to
    /// look at in System Settings.
    ///
    /// The feature still reports `.stopped` on a residue. The user asked
    /// for a stop and both extensions were asked; what failed is the
    /// system accepting the write. Refusing to move to `.stopped` would
    /// leave the screen locked with no way out, and nothing here retries
    /// — the residue is reported once and stays reported until a start
    /// re-registers both extensions.
    enum StopOutcome: Equatable {
        /// Both extensions came down and the system took both writes.
        case landed
        /// Nothing was asked: the feature was already down when the stop
        /// arrived.
        ///
        /// Its own case rather than `.landed`, and the difference is not
        /// cosmetic. Collapsing them let a stop that touched NOTHING
        /// report the same verdict as one that took both extensions
        /// down, so pressing Reset over an already-stopped feature
        /// cleared a residue row while the entry it named was still
        /// registered — the row disappearing on its own, which is the
        /// exact lie the row exists to prevent.
        case alreadyStopped
        /// These did not come down. Display names, ready for a sentence.
        case residue([String])
    }

    /// What a live config change actually did. The caller needs the two
    /// verdicts separately because they fail into different worlds: a
    /// SplitTunnel push that did not land leaves listed apps inside the
    /// tunnel, while a DNSProxy push that did not land leaves their DNS
    /// going to the tunnel's resolver — the asymmetric routing this
    /// architecture exists to prevent.
    ///
    /// `.notRunning` is not a failure and not a success: the payload is
    /// on disk and the next `start` carries it. It is reported rather
    /// than swallowed because the window it names is reachable — a user
    /// editing the list while the feature is still coming up lands here
    /// and nothing tells them their edit did not reach the extensions.
    enum ReconfigureOutcome: Equatable {
        case notRunning
        case pushed(split: ProxyConfigDaemonClient.Push, dns: ProxyConfigDaemonClient.Push)

        /// True only when BOTH extensions answered yes. `.unreachable`
        /// is deliberately not counted as landed even though the push
        /// may have arrived, because a caller that reports state must
        /// not claim what it cannot read.
        var bothLanded: Bool {
            if case .pushed(let split, let dns) = self { return split == .done && dns == .done }
            return false
        }
    }

    /// Live config change. App pushes the new payload to both
    /// extensions independently via XPC `applyConfig` — SplitTunnel
    /// and DNSProxy each through their own daemon client.
    /// BOTH bootstrap blobs are refreshed behind the pushes — DNS
    /// through `enable`, SplitTunnel through `persistConfiguration` —
    /// so a respawn reads the latest list whichever extension it is.
    /// No-op when stopped.
    func reconfigure(with config: SplitTunnelingConfiguration) async -> ReconfigureOutcome {
        var outcome = ReconfigureOutcome.notRunning
        await serialized { [weak self] in
            outcome = await self?.performReconfigure(with: config) ?? .notRunning
        }
        return outcome
    }

    /// Chained, and that is what closes a defect the guard could not:
    /// the `state == .running` check was read ONCE and then the method
    /// spent up to two five-second pushes plus a preference write
    /// suspended, so a `stop()` could complete in the middle and the
    /// tail's `dns.enable` would re-register DNSProxy behind it —
    /// leaving the screen saying stopped, SplitTunnel down, and
    /// DNSProxy enabled with its own bootstrap list.
    private func performReconfigure(with config: SplitTunnelingConfiguration) async -> ReconfigureOutcome {
        guard state == .running else {
            log("reconfigure: state=\(state) → no push (config persisted, applied on next start)")
            return .notRunning
        }
        log("reconfigure: XPC applyConfig → SplitTunnel")
        let splitPush = await splitDaemonClient.applyConfig(config)
        log("reconfigure: SplitTunnel applyConfig \(splitPush.label)")

        log("reconfigure: XPC applyConfig → DNSProxy")
        let dnsPush = await dnsDaemonClient.applyConfig(config)
        log("reconfigure: DNSProxy applyConfig \(dnsPush.label)")

        // Both bootstrap blobs, not just DNS's. This was the asymmetry:
        // the DNS blob was refreshed on every edit while SplitTunnel's
        // stayed frozen at the last `start`, so the two extensions
        // disagreed the moment either respawned — and they respawn
        // without the app in the loop. `persistConfiguration` rather
        // than `enable` because `enable` ends in `startVPNTunnel()`.
        //
        // Logged by outcome. The old line announced the write
        // unconditionally over a `try?` that swallowed it, so someone
        // diagnosing a stale blob read the log and saw a write that
        // never happened.
        var persisted: [String] = []
        do {
            try await split.persistConfiguration(config)
            persisted.append("SplitTunnel ok")
        } catch {
            persisted.append("SplitTunnel FAILED (\(error.localizedDescription))")
        }
        do {
            try await dns.enable(with: config)
            persisted.append("DNSProxy ok")
        } catch {
            persisted.append("DNSProxy FAILED (\(error.localizedDescription))")
        }
        log("reconfigure: bootstrap blobs → \(persisted.joined(separator: ", "))")
        return .pushed(split: splitPush, dns: dnsPush)
    }

    // MARK: - Logging

    private func log(_ message: String) {
        os_log("%{public}@", log: oslog, type: .default, message)
    }
}
