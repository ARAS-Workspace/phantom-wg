#if DEBUG
import Foundation
import NetworkExtension

/// Minimal `TunnelProviding` stand-in. The system cannot hand the
/// harness another user's live session, but a synthetic provider whose
/// id the vault does not back IS one, as far as every classifier and
/// filter in the app can tell — ownership is decided by the
/// owner-scoped vault, never by who minted the object. Records what
/// the code under test does to it (arming, saves, starts) so steps can
/// assert the negative space: what must NOT happen.
///
/// It is also the harness's only way INTO the activation machinery.
/// Three branches of that machinery cannot be reached from outside
/// otherwise, because they need a system that misbehaves in a specific
/// way at a specific moment: a disconnect whose error record arrives
/// late, a disconnect whose record never arrives, and a save that
/// hangs or fails while a rung is mid-flight. Every answer below
/// defaults to the old always-immediate behaviour, so a provider
/// nobody configures behaves exactly as it did before.
final class FakeSlotProvider: TunnelProviding {

    // MARK: - Injectable answers

    /// What `savePreferences` does. `.hangs` never calls back at all,
    /// which is the shape a wedged NE round-trip has.
    enum SaveAnswer {
        case succeeds
        case fails(NSError)
        case succeedsAfter(seconds: Double)
        case hangs
    }

    /// What `fetchLastDisconnectError` answers. The difference between
    /// `.none` and `.never` is the whole point of the drop belt's
    /// deadline: one is "the system says there was no record", the
    /// other is "the system did not say".
    enum DisconnectAnswer {
        case none
        case record(NSError)
        case recordAfter(seconds: Double, NSError)
        case never
    }

    var saveAnswer: SaveAnswer = .succeeds
    /// What `removePreferences` does. A slow answer is the only way to
    /// hold a removal open long enough to drive anything against it,
    /// and removal windows are where the entry-resurrection races live.
    var removeAnswer: SaveAnswer = .succeeds
    var disconnectAnswer: DisconnectAnswer = .none

    /// Handlers for the `.never`/`.hangs` answers, held on purpose. A
    /// real callback API that stays silent RETAINS its handler;
    /// dropping it here instead deallocated the production bridge's
    /// checked continuation unresumed, and the runtime flagged the
    /// intended silence as CONTINUATION MISUSE in every run that drove
    /// it. The awaiting task stays suspended either way — that is the
    /// scenario — but held, it is silence, not misuse.
    /// Typed rather than `[Any]`: every silent surface here answers
    /// `(Error?) -> Void`, and a stored-as-`Any` closure would have to
    /// be cast back to be released — a cast whose failure would be
    /// silent, which is the one thing a cleanup net must not be.
    private var heldCompletions: [@Sendable (Error?) -> Void] = []

    // MARK: - Observed state

    var localizedDescription: String?
    var isEnabled = false
    private(set) var identity: TunnelIdentity?
    var tunnelIdentity: TunnelIdentity? { identity }
    func configure(with identity: TunnelIdentity) { self.identity = identity }
    var isOnDemandEnabled = false
    /// What the STORE holds, as opposed to the flag this process
    /// carries. Production keeps the two apart on purpose — a refused
    /// save leaves the flag written and the store unknown, which is
    /// why `standDownRecovery` re-reads instead of guessing — and while
    /// both lived in one variable here the fake answered every re-read
    /// with the value the app had just written. Two things were
    /// invisible because of it: a rule surviving in the store under a
    /// flag that reads disarmed (the state the rung-0 sweep exists to
    /// clear), and the re-read repair itself, which could never be
    /// observed reporting anything but success.
    ///
    /// Written only where the system writes it: a save that ANSWERS
    /// lands the value that save carried. A refusal, and a silence
    /// released as a refusal, leave it alone.
    private(set) var storedOnDemand = false
    var onDemandRules: [NEOnDemandRule]?
    private(set) var connectionStatus: NEVPNStatus
    private(set) var saveCount = 0
    /// Counts the re-reads, so a step can prove the repair path RAN
    /// rather than infer it from a value the rollback would have
    /// produced too.
    private(set) var loadCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var removeCount = 0

    init(name: String?, identity: TunnelIdentity?, status: NEVPNStatus) {
        self.localizedDescription = name
        self.identity = identity
        self.connectionStatus = status
    }

    // MARK: - Driving the manager

    /// Moves the session and publishes the change the way the system
    /// does, so the manager's observer runs its real handler over it.
    ///
    /// Delivery is same-name, different object: the observer listens
    /// with `object: nil` and picks the tunnel by asking each provider
    /// `matchesNotification`. Ours answers only for a notification
    /// carrying THIS instance, and the production provider answers
    /// only for its own `NETunnelProviderSession` — so a driven
    /// notification can never be picked up by a real tunnel, and a
    /// real system notification can never be picked up by a fake. That
    /// isolation is what makes it safe to drive one from inside a live
    /// app.
    func drive(_ status: NEVPNStatus) {
        connectionStatus = status
        NotificationCenter.default.post(name: .NEVPNStatusDidChange, object: self)
    }

    /// Sets the session without publishing anything — for arranging a
    /// starting state the manager should not react to yet.
    func setStatusSilently(_ status: NEVPNStatus) {
        connectionStatus = status
    }

    /// Arranges the ORDINARY armed state: the flag, the store and the
    /// rule together, the way a provider loaded from the system comes
    /// in — production never writes the flag without the
    /// connect-on-any-network rule beside it (`armRecovery`), and a
    /// step that reads the rules must not find them empty under an
    /// armed flag. A step that wants the flag and the store DIVERGED —
    /// the flag written over a save that never landed — drives the
    /// production path that produces it rather than setting the pair by
    /// hand.
    ///
    /// One direction only: a provider is born disarmed, so "arrange
    /// disarmed" would be a call that describes the initial state, and
    /// its rule-clearing half would model something production never
    /// does — `standDownRecovery` lowers the flag and leaves the rule
    /// object where it is.
    func arrangeArmed() {
        isOnDemandEnabled = true
        storedOnDemand = true
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        onDemandRules = [rule]
    }

    /// Answers every completion this provider is holding, so a step
    /// that drove `.hangs` or `.never` can end its own silence.
    ///
    /// A held completion is not just a suspended caller: it is a
    /// checked continuation inside the production bridge. How much it
    /// pins depends on the surface. A held SAVE suspends the task
    /// that issued it, and the families a step can wedge through the
    /// activation path are four — a rung's arm save, the STOP's own
    /// disarm, a withdrawal's stand-down, and rung 0's sweep, which
    /// issues one per OTHER tunnel on every activation. (`remove()`'s
    /// sequenced disarm and the gate's engage sweep ride the same
    /// surface and are drained by the same net.) All of them call the
    /// manager across the save, so all of them hold it for as long as
    /// the silence lasts; the drain below, not a capture list, is what
    /// ends that. The rung is the expensive
    /// one: it holds the manager that owns this provider past the
    /// await, so left alone the side manager outlives the step. In a
    /// rig that kept the reload triggers that leak would keep running
    /// real vault passes for the rest of the app's session; the
    /// wedging steps opt out of those triggers, so the standing
    /// residue is a status-observer-only manager — smaller, still a
    /// leak. The withdrawal's stand-down and the stop's are the gated
    /// kind: the gate is a method ON the manager, so the manager is
    /// live across the save by construction and no capture list can
    /// shorten that — a step wedging either family relies on the
    /// drain. A held FETCH pins less still: its belt rode
    /// `bounded` and moved on, leaving the suspended producer with the
    /// container and this provider. Held silence is residue in every
    /// family, and draining here ends them all.
    ///
    /// For the SAVE families the error is what the system would report
    /// for a request that cannot be completed, so the resumed caller
    /// takes its ordinary failure path. The FETCH family's parameter
    /// is an answer channel, not a failure channel — a released fetch
    /// delivers a fabricated disconnect RECORD — and that is safe only
    /// because every fetch here rides `bounded`, whose race answered
    /// long before any teardown runs: the late record falls to the
    /// `SingleResume` and is dropped, never filed.
    @discardableResult
    func releaseHeldCompletions() -> Int {
        let held = heldCompletions
        heldCompletions.removeAll()
        let cancelled = NSError(domain: "TE.Seam", code: 44,
                                userInfo: [NSLocalizedDescriptionKey: "test rig released a held request"])
        for completion in held { completion(cancelled) }
        return held.count
    }

    // MARK: - TunnelProviding

    func startTunnel() throws {
        startCount += 1
    }

    func stopTunnel() { stopCount += 1 }

    func sendProviderMessage(_ data: Data, responseHandler: @escaping @Sendable (Data?) -> Void) throws {
        responseHandler(nil)
    }

    func savePreferences(completion: @escaping @Sendable (Error?) -> Void) {
        saveCount += 1
        switch saveAnswer {
        case .succeeds:
            storedOnDemand = isOnDemandEnabled
            completion(nil)
        case .fails(let error):
            completion(error)
        case .succeedsAfter(let seconds):
            // The value this save carries, read at ISSUE: a save writes
            // what its caller wrote, not what the flag happens to say
            // when the answer finally arrives. What decides the ORDER
            // two in-flight saves land in is the deadline, not the
            // issue — equal delays make them agree, so a step must not
            // change `saveAnswer`'s delay while a save is still in
            // flight. The reference is weak and the completion
            // `@Sendable`, so the delay still cannot keep this provider
            // alive past the step that planted it.
            let landing = isOnDemandEnabled
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.storedOnDemand = landing
                completion(nil)
            }
        case .hangs:
            heldCompletions.append(completion)
        }
    }

    /// The store's own answer, which is the whole point of the re-read
    /// on a refused disarm: a load repaints the flag from what is
    /// actually stored. Answering success while painting nothing made
    /// every re-read agree with the app, so the divergence this fake
    /// now models could not be produced at all.
    ///
    /// Only the SUCCESSFUL half of that re-read is reachable from here:
    /// this load cannot fail, so `standDownRecovery`'s pessimistic
    /// fallback — restoring the entry value when even the re-read is
    /// refused — is still uncovered and waits on an injectable answer.
    /// It repaints the on-demand flag alone; a real load restores the
    /// whole configuration, which is why the projection rollback in
    /// `modify()` cannot be measured through this surface either.
    func loadPreferences(completion: @escaping @Sendable (Error?) -> Void) {
        loadCount += 1
        isOnDemandEnabled = storedOnDemand
        completion(nil)
    }

    /// The store's second writer: a removal takes the configuration and
    /// its rule together, so an entry that answered a remove cannot go
    /// on reporting a stored rule — this object outlives the entry
    /// (the factory hands the same instance back), and a later re-read
    /// would otherwise paint a flag for something that is gone.
    func removePreferences(completion: @escaping @Sendable (Error?) -> Void) {
        removeCount += 1
        switch removeAnswer {
        case .succeeds:
            storedOnDemand = false
            completion(nil)
        case .fails(let error):
            completion(error)
        case .succeedsAfter(let seconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.storedOnDemand = false
                completion(nil)
            }
        case .hangs:
            heldCompletions.append(completion)
        }
    }

    func matchesNotification(_ notification: Notification) -> Bool {
        (notification.object as AnyObject?) === self
    }

    func fetchLastDisconnectError(completion: @escaping @Sendable (Error?) -> Void) {
        switch disconnectAnswer {
        case .none:
            completion(nil)
        case .record(let error):
            completion(error)
        case .recordAfter(let seconds, let error):
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { completion(error) }
        case .never:
            heldCompletions.append(completion)
        }
    }
}

/// Hands a manager a fixed set of providers instead of the system's.
struct FakeSlotFactory: TunnelProviderFactory {
    let canned: [TunnelProviding]
    func makeProvider() -> TunnelProviding {
        FakeSlotProvider(name: nil, identity: nil, status: .invalid)
    }
    func loadAllFromPreferences() async throws -> [TunnelProviding] { canned }
}
#endif
