import Foundation
import SystemExtensions
import os.log

/// The one way this app reaches the system-extension framework, behind
/// a seam.
///
/// `OSSystemExtensionManager.shared` is a process-wide singleton and
/// every submission through it is real: an activation stages an
/// install, a deactivation takes an extension down, and the user's own
/// machine answers. So the surfaces the gate controller owns — the
/// approval budget, the answer that lands after this app stopped
/// waiting for it, the gate state each of those produces — could not be
/// driven from a step at all, because driving them meant installing and
/// removing the user's extensions for real.
///
/// What makes a seam here work is that building a request is inert;
/// only submitting it is not. A substitute that captures a request and
/// never submits it hands a step the entire delegate lifecycle — the
/// request object is a genuine one, and its delegate is already wired
/// by the caller — with nothing at all reaching the system extension
/// store.
///
/// Deliberately ONE method: not an abstraction over the framework, just
/// the single call site that has to be interceptable. Everything else
/// the controller does with a request (constructing it, holding it,
/// comparing identities) stays exactly as it is.
protocol SystemExtensionSubmitting {
    func submit(_ request: OSSystemExtensionRequest)
}

/// The production submitter: the singleton, called the way it always
/// was.
struct RealSystemExtensionSubmitter: SystemExtensionSubmitting {
    func submit(_ request: OSSystemExtensionRequest) {
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

/// Generic activation / approval / deactivation surface for a single
/// system extension bundle. One instance per extension; the app's
/// three extensions (Tunnel / Split-Tunnel / DNSProxy) each own their
/// own controller and the `ExtensionGateCoordinator` aggregates them.
///
/// The controller interprets every `OSSystemExtensionRequest` signal
/// Apple emits — `propertiesRequest`, `requestNeedsUserApproval`,
/// `didFinishWithResult`, `didFailWithError` — and projects them onto
/// a single `Status` enum the gate UI consumes. Behaviour mirrors what
/// is required to be battle-tested across the user-driven scenarios:
/// cold boot with the extension already enabled, fresh install,
/// installed-but-disabled-in-System-Settings, replacement upgrade,
/// uninstall, and every documented `OSSystemExtensionError` code.
///
/// State changes come from two doors only: the boot measurement
/// (`settle()`, once per process) and user actions (`activate()` /
/// `refresh()` / `deactivate()`), each resolved through delegate
/// callbacks. There is no background polling and no notification
/// observer in this controller; runtime drop-back detection lives in
/// the coordinator — workspace transition pushes plus an app-foreground
/// re-check belt (see `ExtensionGateCoordinator.start()`).
@Observable
@MainActor
final class ExtensionGateController: NSObject, OSSystemExtensionRequestDelegate {

    enum Status: Equatable {
        case unknown
        case notInstalled
        case activating
        case needsApproval
        case activated
        case failed(String)
    }

    /// One measurement of the installed extension's build identity.
    /// Answers `ExtensionIdentity.current` as computed inside the
    /// running extension, or `nil` when the daemon did not answer.
    typealias IdentityProbe = @MainActor () async -> String?

    let bundleID: String
    let displayName: String

    private(set) var status: Status = .unknown

    /// True while `settle()` is measuring. `checkAll()` skips a
    /// settling controller so a foreground refresh landing mid-
    /// measurement cannot write a transient verdict over the tree.
    private(set) var isSettling = false

    @ObservationIgnored private var deactivationContinuation: CheckedContinuation<Void, Error>?
    /// The request that continuation belongs to. Held because the
    /// terminal callbacks are delivered for EVERY request this
    /// controller has in flight, and an open ledger cannot tell them
    /// apart: a failing activation would otherwise resolve a pending
    /// deactivation with a foreign error, and the real answer — landing
    /// later to an empty ledger — would be dropped on the floor. The
    /// settle probe next to it already demuxes by identity; this is the
    /// same test, applied to the request that can strand a teardown.
    @ObservationIgnored private var deactivationRequest: OSSystemExtensionRequest?
    /// The ceiling under that continuation, and the reason it exists is
    /// not the system: it is the USER, who may never answer the approval
    /// prompt a deactivation raises.
    ///
    /// Everything else the uninstall flow does is bounded. This await
    /// was not, and what hangs on it is not just the flow: the flow
    /// raises the refresh latch and lowers it from a `defer`, and a
    /// `defer` only runs when the scope ENDS. A prompt nobody answers
    /// therefore left the latch up for the life of the process, with
    /// ingest, restore and realign all dead behind it and no cure but a
    /// relaunch.
    ///
    /// The gate had a second door for exactly this, keyed to the gate
    /// leaving readiness and coming back — but the only thing that used
    /// to take it out of readiness during a parked teardown was the
    /// `.needsApproval` paint, which is the WRONG status for a removal
    /// and was rightly removed. Rather than manufacture a state change
    /// for a net to watch, the wait itself is bounded here, which is
    /// what every other unresolved await in this app already does.
    @ObservationIgnored private var deactivationDeadline: Task<Void, Never>?
    /// Deactivations this controller stopped waiting on, kept so their
    /// terminal callbacks are still recognised for what they are.
    ///
    /// macOS holds a submitted request whatever we do — there is no
    /// cancel API, the delegate stays wired, and the answer arrives
    /// whenever the user finally acts. Clearing the identity pointer on
    /// the budget's way out therefore did not make the request go away;
    /// it made the late answer demux as an ACTIVATION, and the gate
    /// painted `.needsApproval` over an extension that had just been
    /// removed — offering the user a button that reinstalls it. That is
    /// the exact wrongness this controller's approval branch was changed
    /// to stop telling, arriving by another door.
    ///
    /// Identities rather than the objects: nothing here needs to keep a
    /// request alive, only to recognise one.
    @ObservationIgnored private var abandonedDeactivations: Set<ObjectIdentifier> = []

    /// The daemon probe injected at composition. `nil` (previews, or
    /// a composition without clients) makes `settle()` fall back to a
    /// plain `activate()` — the pre-measurement boot behavior.
    @ObservationIgnored private let identityProbe: IdentityProbe?

    /// How this controller reaches the framework. Every request it
    /// submits goes through here and nowhere else, which is what makes
    /// the seam a seam — see `SystemExtensionSubmitting`.
    @ObservationIgnored private let submitter: SystemExtensionSubmitting

    /// One-shot bridge between `settle()` and the delegate: the
    /// properties request `settle` submits is remembered by object
    /// identity, and its callbacks resolve this continuation with raw
    /// facts instead of running the normal status interpretation —
    /// the measurement tree owns the verdict while it is settling.
    @ObservationIgnored private var settleContinuation: CheckedContinuation<PropsVerdict, Never>?
    @ObservationIgnored private var settlePropsRequest: OSSystemExtensionRequest?

    /// Raw facts a settle-issued properties query can answer with.
    private enum PropsVerdict {
        /// No live registration — nothing is running for this bundle.
        case noLive
        /// Registered but awaiting approval or toggled off in System
        /// Settings; activation cannot repair either.
        case awaiting
        /// Registered and enabled — the extension should be alive.
        case enabled
        /// The query itself failed; teaches nothing.
        case inconclusive
    }

    /// True between an activation request resolving `.completed` and
    /// the follow-up `propertiesRequest` arriving. Apple returns an
    /// empty `propertiesRequest` array for extensions that are
    /// registered but disabled in System Settings (toggle off), which
    /// is indistinguishable from "truly not installed" without this
    /// hint — `.completed` only fires when the extension is known to
    /// the system, so an empty reply in that window means the user
    /// must re-enable it in Settings.
    @ObservationIgnored private var pendingActivationCompleted = false

    /// Count of activation requests submitted and not yet resolved by
    /// a terminal callback (`didFinishWithResult` / `didFailWithError`).
    /// While non-zero, `foundProperties` must not promote to
    /// `.activated`: during a replacement the properties query happily
    /// reports the outgoing extension as enabled, and an early
    /// promotion reopens the gate while the provider kill is still in
    /// flight (field-measured: `allReady` flipped, downstream boot
    /// logic ran, and `stopTunnel` landed moments later). The
    /// promotion belongs to the completion path — `didFinishWithResult`
    /// → `refresh()` → here, with this counter back at zero. A counter
    /// rather than a flag so a second `activate()` superseding the
    /// first keeps its own protection when the first request's failure
    /// callback lands.
    @ObservationIgnored private var activationsInFlight = 0

    @ObservationIgnored private let oslog: OSLog

    /// Production always starts at `.unknown` and lets the delegate
    /// callbacks settle the real state; previews pass a fixed `status`
    /// to render a specific gate scenario.
    ///
    /// The last two parameters carry production values and exist so a
    /// step can supply its own — the same shape `TunnelsManager` uses
    /// for its retry pacing and its reload observation. Nothing in the
    /// app passes either.
    init(
        bundleID: String,
        displayName: String,
        status: Status = .unknown,
        identityProbe: IdentityProbe? = nil,
        submitter: SystemExtensionSubmitting = RealSystemExtensionSubmitter(),
        deactivationBudget: Duration = .seconds(60)
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.oslog = OSLog(
            subsystem: "com.remrearas.Phantom-WG-MacOS",
            category: "gate.\(displayName)"
        )
        self.status = status
        self.identityProbe = identityProbe
        self.submitter = submitter
        self.deactivationBudget = deactivationBudget
        super.init()
    }

    private func log(_ message: String) {
        os_log("%{public}@", log: oslog, type: .default, message)
    }

    // MARK: - Public Surface

    /// Measured boot entry. `activate()` on an installed extension is
    /// not a no-op — the OS stages a full replacement even for a
    /// byte-identical bundle and kills its running sessions — so the
    /// boot pass measures first and activates only when the
    /// measurement demands it:
    ///
    /// - probe answers, identity matches → `.activated`, nothing else
    /// - probe answers, identity differs → stale binary → `activate()`
    /// - probe silent → one properties query decides: no registration
    ///   means activating harms nobody; awaiting/disabled means the
    ///   gate guides the user (activation cannot repair it); enabled
    ///   means transient — retry with patience
    ///
    /// Silence alone never activates immediately. The one bounded
    /// exception: an extension that stays silent through every patient
    /// round while properties either call it enabled OR cannot be queried at all is a daemon that cannot
    /// speak identity — a binary from before the identity contract, or
    /// a wedged process. Both are exactly what a replacement repairs.
    func settle() async {
        guard let identityProbe else {
            log("settle: no probe injected → activate()")
            activate()
            return
        }
        guard !isSettling else { return }
        isSettling = true
        defer { isSettling = false }

        for attempt in 1...Self.settleAttempts {
            if let identity = await identityProbe() {
                if identity == ExtensionIdentity.current {
                    log("settle: identity match (\(identity)) — activation skipped")
                    status = .activated
                } else {
                    log("settle: identity mismatch — installed \(identity), expected \(ExtensionIdentity.current) → activate()")
                    activate()
                }
                return
            }

            let verdict = await propertiesVerdict()
            switch verdict {
            case .noLive:
                log("settle: probe silent + no live entry → activate()")
                activate()
                return
            case .awaiting:
                log("settle: probe silent + awaiting/disabled → .needsApproval")
                status = .needsApproval
                return
            case .enabled, .inconclusive:
                // Both arms land here and the sentence must say which: `.enabled`
                // is field evidence, `.inconclusive` is the absence of any.
                // Printed as one word for years, it sent diagnosis after a
                // property the query never returned.
                log("settle: probe silent, properties \(verdict) — attempt \(attempt)/\(Self.settleAttempts)")
                if attempt < Self.settleAttempts {
                    try? await Task.sleep(for: .milliseconds(600 * attempt))
                }
            }
        }

        log("settle: measurement exhausted — daemon cannot speak identity → activate()")
        activate()
    }

    private static let settleAttempts = 3

    /// One-shot properties query owned by the settle tree. The
    /// delegate resolves it with raw facts via `settlePropsRequest`
    /// identity instead of the normal status interpretation.
    private func propertiesVerdict() async -> PropsVerdict {
        await withCheckedContinuation { (continuation: CheckedContinuation<PropsVerdict, Never>) in
            settleContinuation = continuation
            let request = OSSystemExtensionRequest.propertiesRequest(
                forExtensionWithIdentifier: bundleID,
                queue: .main
            )
            settlePropsRequest = request
            request.delegate = self
            submitter.submit(request)
        }
    }

    /// Submit an activation request. Not a harmless no-op: even for a
    /// byte-identical installed bundle the OS stages a full
    /// replacement and kills the extension's running sessions
    /// (field-measured) — which is why `settle()` measures before
    /// calling this. If the extension is missing macOS installs it,
    /// if approval is missing macOS surfaces the prompt. The
    /// follow-up `propertiesRequest` is the authority on actual
    /// enabled state because Apple resolves `.completed` even for
    /// installed-but-disabled extensions.
    func activate() {
        log("activate() submitted (bundleID=\(bundleID), status=\(status))")
        pendingActivationCompleted = false
        activationsInFlight += 1
        if status != .needsApproval {
            status = .activating
        }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: bundleID,
            queue: .main
        )
        request.delegate = self
        submitter.submit(request)
    }

    /// Pull ground-truth state from the OS. The delegate writes the
    /// reply into `status` via `request(_:foundProperties:)`.
    func refresh() {
        log("refresh() submitted (status=\(status))")
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: bundleID,
            queue: .main
        )
        request.delegate = self
        submitter.submit(request)
    }

    /// Refusals this controller raises itself, as opposed to the ones
    /// the system hands back.
    ///
    /// Localized, because both of them reach the user: the uninstall
    /// flow puts `localizedDescription` straight into its alert, and an
    /// unconformed error there reads as "The operation couldn't be
    /// completed. (ExtensionGateError error 1.)".
    enum ExtensionGateError: Error, LocalizedError {
        /// A second `deactivate()` arrived while one was still
        /// awaiting its delegate callback.
        case deactivationAlreadyInFlight
        /// The approval prompt went unanswered for the whole budget, so
        /// the flow was handed its answer back rather than left holding
        /// the refresh latch. The removal itself is NOT cancelled — the
        /// system keeps the request, and approving it later still takes
        /// the extension down; what ended is this app's wait on it.
        case deactivationNotAnswered

        var errorDescription: String? {
            let loc = LocalizationManager.shared
            switch self {
            case .deactivationAlreadyInFlight:
                return loc.t("error_uninstall_already_running")
            case .deactivationNotAnswered:
                return loc.t("error_uninstall_not_approved")
            }
        }
    }

    /// How long a deactivation may wait on its approval prompt.
    ///
    /// The number is not a guess about macOS — the system answers in
    /// milliseconds once the user acts. It is what this app is willing
    /// to spend holding every self-heal shut while a dialog goes
    /// unanswered, and the two costs it sits between are asymmetric: a
    /// user still reading the prompt loses an uninstall they can start
    /// again with the reason named, while a user who has walked away
    /// otherwise loses the running app until they relaunch it. The
    /// uninstall awaits three of these but `uninstallAll` is sequential
    /// and throws on the first, so the worst case is one budget, not
    /// three.
    ///
    /// Held per instance rather than as a type constant because a step
    /// proving the budget ENDS the wait has to outlast it, and no step
    /// may sit for a minute. Sixty seconds is what the app is composed
    /// with; what a step shortens is only how long it waits for the
    /// same path to run.
    @ObservationIgnored private let deactivationBudget: Duration

    /// Submit a deactivation request and await completion. Throws on
    /// hard error, resolves to `.notInstalled` on success.
    func deactivate() async throws {
        // "requested", not "submitted": this line prints BEFORE the
        // re-entrance guard below, so a second press reaches it too and
        // the old wording announced a submission the very next line
        // refuses. The harness counts real submissions, and a log that
        // disagrees with that count is the copy that gets believed.
        log("deactivate() requested (status=\(status))")
        // One AWAITED deactivation at a time — the SYSTEM may well hold
        // more, since a budget that gives up cancels nothing; see
        // `resumeDeactivation` for what that costs and how the exit is
        // keyed. A second call would overwrite the
        // stored continuation and strand the first caller for ever —
        // nothing would ever resume it — and the uninstall flow awaits
        // three of these in sequence, so a stall there stops the whole
        // teardown with no error to show for it.
        if deactivationContinuation != nil {
            log("deactivate() refused — one is already in flight")
            throw ExtensionGateError.deactivationAlreadyInFlight
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.deactivationContinuation = continuation
            let request = OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: bundleID,
                queue: .main
            )
            self.deactivationRequest = request
            request.delegate = self
            submitter.submit(request)
            // Armed after the submit, and what that order buys is
            // narrower than it looks: a deadline is never armed for a
            // request that was never handed over. It is NOT protection
            // against a synchronous failure, because there is no such
            // thing here — every delegate callback hops to the main
            // actor before it runs, so none of them can land inside
            // `submit` whatever order this code is written in. Whoever
            // gets there first, `resumeDeactivation` is the single exit
            // and it cancels this task on its way through.
            //
            // The budget is read HERE, not inside the task: a weak
            // `self` that has gone would otherwise need a fallback
            // number, and a second copy of this ceiling is exactly the
            // kind of duplicate that drifts from the one above it.
            let budget = self.deactivationBudget
            self.deactivationDeadline = Task { @MainActor [weak self] in
                try? await Task.sleep(for: budget)
                guard !Task.isCancelled, let self else { return }
                self.log("deactivate() gave up waiting on the approval prompt"
                         + " — the flow gets its answer back and the refresh latch comes down with it")
                // Remembered BEFORE the pointer is cleared. Giving up on
                // an answer is not the same as the answer never coming,
                // and the callback that eventually lands has to be read
                // as the removal it is.
                self.abandonedDeactivations.insert(ObjectIdentifier(request))
                self.resumeDeactivation(request, with: .failure(ExtensionGateError.deactivationNotAnswered))
            }
        }
    }

    /// Whether a callback belongs to a removal this controller asked
    /// for — the one still being awaited, or one it gave up waiting on.
    ///
    /// Both are removals as far as the SYSTEM is concerned, and the gate
    /// state each produces is the same: the extension is going, or gone.
    ///
    /// What differs is the app's own WAIT, and the difference is not
    /// spent when the callback arrives — it is the whole reason
    /// `resumeDeactivation` takes a request. This answers "is this a
    /// removal of ours", never "is this the removal we are waiting on";
    /// the second question has exactly one right answer and only the
    /// identity pointer holds it.
    private func isOurDeactivation(_ request: OSSystemExtensionRequest) -> Bool {
        request === deactivationRequest || abandonedDeactivations.contains(ObjectIdentifier(request))
    }

    /// The single exit for that continuation, and it belongs to ONE
    /// request — which is why the request has to be named.
    ///
    /// Giving up on an answer does not cancel the request, and it does
    /// not stop the user: the alert says the uninstall can be started
    /// again, and the re-entrance guard above is keyed to the
    /// continuation the budget has just cleared, so starting again is
    /// exactly what it admits. From that moment two removals are live —
    /// the one the system still holds and the one this app is waiting
    /// on — and an exit guarded only on the continuation's EXISTENCE
    /// hands the first one's answer to the second one's caller. Worse
    /// than the wrong answer: it also clears the pointer, so the second
    /// request's own answer lands as a stranger and takes the
    /// ACTIVATION branch, painting `.needsApproval` over an extension
    /// that was just removed. That is the wrongness the abandoned
    /// ledger was added to stop, arriving by a third door.
    ///
    /// So a late answer for an abandoned request resumes nothing, keeps
    /// the live deadline armed, and leaves the pointer where it is. It
    /// still carries its own gate state — the extension really is gone
    /// — which is the reason the ledger exists at all.
    private func resumeDeactivation(_ request: OSSystemExtensionRequest, with result: Result<Void, Error>) {
        guard request === deactivationRequest else { return }
        deactivationDeadline?.cancel()
        deactivationDeadline = nil
        guard let continuation = deactivationContinuation else { return }
        deactivationContinuation = nil
        deactivationRequest = nil
        continuation.resume(with: result)
    }

    // MARK: - OSSystemExtensionRequestDelegate

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        Task { @MainActor in
            log("actionForReplacingExtension: \(existing.bundleShortVersion) → \(ext.bundleShortVersion)")
        }
        return .replace
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        Task { @MainActor in
            // A settle-issued query resolves the measurement tree's
            // continuation with raw facts; the normal interpretation
            // below serves refresh()/checkAll() only.
            if request === settlePropsRequest {
                settlePropsRequest = nil
                let live = properties.filter { !$0.isUninstalling }
                let verdict: PropsVerdict
                if let liveProp = pickLive(from: live) {
                    verdict = (liveProp.isAwaitingUserApproval || !liveProp.isEnabled)
                        ? .awaiting : .enabled
                } else {
                    verdict = .noLive
                }
                log("foundProperties (settle) total=\(properties.count) live=\(live.count) → \(verdict)")
                settleContinuation?.resume(returning: verdict)
                settleContinuation = nil
                return
            }

            // `propertiesRequest` returns *every* extension version
            // the system has seen for this bundle ID — including
            // historical orphans that are still draining out of the
            // system extension store. Those carry `isUninstalling =
            // true`. The live version (if any) is the one with
            // `isUninstalling = false`; orphans must be filtered out
            // before any flag is interpreted.
            let live = properties.filter { !$0.isUninstalling }
            log("foundProperties total=\(properties.count) live=\(live.count) pending=\(pendingActivationCompleted) status=\(status)")
            let pending = pendingActivationCompleted
            pendingActivationCompleted = false

            guard let liveProp = pickLive(from: live) else {
                // No live entry — every property is an orphan being
                // uninstalled, or the array is empty. Right after
                // an activation request resolved `.completed` the
                // extension is known to the system, so this window
                // means the user has it disabled in System Settings.
                // Outside that window the cold boot `.unknown`
                // snapshot is taken as "truly not installed";
                // otherwise it is a transient OS query lag.
                if pending {
                    log("→ no live entry + pending → .needsApproval (installed-but-disabled)")
                    status = .needsApproval
                } else if status == .unknown {
                    log("→ no live entry + unknown → .notInstalled")
                    status = .notInstalled
                } else {
                    log("→ no live entry + status=\(status) → no-op (transient)")
                }
                return
            }

            log("→ live: isEnabled=\(liveProp.isEnabled),isAwaiting=\(liveProp.isAwaitingUserApproval),v\(liveProp.bundleShortVersion)")

            if liveProp.isAwaitingUserApproval {
                log("→ live.isAwaitingUserApproval=true → .needsApproval")
                status = .needsApproval
                return
            }
            if liveProp.isEnabled {
                // Only the promotion is held — `.needsApproval` /
                // `.notInstalled` transitions above stay live so the
                // approval flow never deadlocks on this counter.
                guard activationsInFlight == 0 else {
                    log("→ live.isEnabled=true, activation in flight → holding \(status)")
                    return
                }
                log("→ live.isEnabled=true → .activated")
                status = .activated
            } else {
                // Live entry exists but is disabled in System
                // Settings. The activation API cannot re-enable it;
                // the user must flip the toggle themselves, so the
                // gate guides them to System Settings.
                log("→ live.isEnabled=false → .needsApproval (toggle off)")
                status = .needsApproval
            }
        }
    }

    /// Picks the most authoritative live entry from a non-orphan
    /// subset. Apple may report duplicate live versions during a
    /// replacement upgrade; preferring `isEnabled` then
    /// `isAwaitingUserApproval` makes the chosen entry reflect the
    /// version the system is actually running.
    private func pickLive(from live: [OSSystemExtensionProperties]) -> OSSystemExtensionProperties? {
        if let enabled = live.first(where: { $0.isEnabled }) {
            return enabled
        }
        if let awaiting = live.first(where: { $0.isAwaitingUserApproval }) {
            return awaiting
        }
        return live.first
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            // A DEACTIVATION can need approval too, and painting the
            // gate `.needsApproval` for it says the opposite of what
            // happened: that status is the install story — "this
            // extension is waiting to be allowed IN" — and the gate
            // screen it drives offers the user Settings to approve an
            // extension they just asked to remove. The teardown is
            // still legitimately parked on the prompt, so nothing is
            // resumed here; it is named instead, because this line is
            // the only field evidence that a teardown is sitting on a
            // dialog. Not resuming it is safe now in a way it was not
            // when this branch was written: the wait carries its own
            // budget, so an unanswered prompt ends the flow rather than
            // outliving the process. Leaving the gate state alone here
            // is what makes that budget the ONLY thing that ends it,
            // which is the point — one exit, named, with a deadline.
            guard !isOurDeactivation(request) else {
                log("requestNeedsUserApproval on the DEACTIVATION — waiting on the user, gate state left alone")
                return
            }
            log("requestNeedsUserApproval → .needsApproval")
            status = .needsApproval
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            log("didFinishWithResult: \(result.rawValue) (deactivating=\(isOurDeactivation(request)))")
            if isOurDeactivation(request) {
                // Answered, so the ledger is done with it. Discarded
                // here rather than inside `resumeDeactivation`, which
                // an abandoned request's answer deliberately does not
                // get past — that exit belongs to the request this app
                // is currently waiting on, and this one is not it.
                abandonedDeactivations.remove(ObjectIdentifier(request))
                // `.willCompleteAfterReboot` is a legal deactivation
                // outcome: the request succeeded but the provider may
                // keep running until the machine restarts. The flow
                // continues either way — preference entries are
                // independent of the running provider — but the
                // pending state is named instead of being folded
                // silently into success; the gate's normal boot
                // measurement re-proves reality on the next launch.
                if result == .willCompleteAfterReboot {
                    log("deactivation will complete after reboot — the provider may keep running until then")
                }
                status = .notInstalled
                resumeDeactivation(request, with: .success(()))
                return
            }
            activationsInFlight = max(0, activationsInFlight - 1)
            switch result {
            case .completed:
                // `.completed` only signals that the activation
                // request finished — Apple resolves it even when the
                // extension is installed but disabled. The properties
                // query is the authority on whether the gate should
                // advance, so re-issue it and let `foundProperties`
                // drive the final state. The `pendingActivationCompleted`
                // hint is what disambiguates an empty reply in that
                // window from "truly not installed".
                pendingActivationCompleted = true
                refresh()
            case .willCompleteAfterReboot:
                status = .needsApproval
            @unknown default:
                refresh()
            }
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        let nsError = error as NSError
        let code = nsError.code
        let domain = nsError.domain
        Task { @MainActor in
            log("didFailWithError: domain=\(domain) code=\(code) — \(error.localizedDescription)")
            if request === settlePropsRequest {
                settlePropsRequest = nil
                settleContinuation?.resume(returning: .inconclusive)
                settleContinuation = nil
                return
            }
            if isOurDeactivation(request) {
                abandonedDeactivations.remove(ObjectIdentifier(request))
                resumeDeactivation(request, with: .failure(error))
                return
            }
            activationsInFlight = max(0, activationsInFlight - 1)
            guard domain == OSSystemExtensionErrorDomain else {
                status = .failed(error.localizedDescription)
                return
            }
            handleActivationFailure(code: code, error: error)
        }
    }

    // MARK: - Failure Mapping

    private func handleActivationFailure(code: Int, error: Error) {
        let loc = LocalizationManager.shared
        switch OSSystemExtensionError.Code(rawValue: code) {
        case .requestCanceled, .requestSuperseded:
            log("→ requestCanceled/Superseded — no-op")
            return
        case .authorizationRequired:
            log("→ authorizationRequired → .needsApproval")
            status = .needsApproval
        case .extensionNotFound:
            log("→ extensionNotFound → .notInstalled")
            status = .notInstalled
        case .unsupportedParentBundleLocation:
            log("→ unsupportedParentBundleLocation → .failed")
            status = .failed(loc.t("sysext_err_unsupported_location"))
        case .codeSignatureInvalid:
            log("→ codeSignatureInvalid → .failed")
            status = .failed(loc.t("sysext_err_code_signature"))
        case .validationFailed:
            log("→ validationFailed → .failed")
            status = .failed(loc.t("sysext_err_validation"))
        case .forbiddenBySystemPolicy:
            log("→ forbiddenBySystemPolicy → .failed")
            status = .failed(loc.t("sysext_err_system_policy"))
        case .missingEntitlement:
            log("→ missingEntitlement → .failed")
            status = .failed(loc.t("sysext_err_entitlement"))
        default:
            log("→ unknown sysext error code \(code) → .failed")
            status = .failed(loc.t("sysext_err_unknown", code, error.localizedDescription))
        }
    }
}
