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
    var onDemandRules: [NEOnDemandRule]?
    private(set) var connectionStatus: NEVPNStatus
    private(set) var saveCount = 0
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

    /// Answers every completion this provider is holding, so a step
    /// that drove `.hangs` or `.never` can end its own silence.
    ///
    /// A held completion is not just a suspended caller: it is a
    /// checked continuation inside the production bridge. How much it
    /// pins depends on the surface. A held SAVE suspends the task
    /// that issued it, and two families do — a rung's arm save and a
    /// withdrawal's stand-down. The rung is the expensive one: it
    /// holds the manager that owns this provider past the await, so
    /// left alone the side manager outlives the step. In a rig that
    /// kept the reload triggers that leak would keep running real
    /// vault passes for the rest of the app's session; the wedging
    /// steps opt out of those triggers, so the standing residue is a
    /// status-observer-only manager — smaller, still a leak. The withdrawal's task needs only the container past
    /// the save — its last use of the manager comes before it — but
    /// ARC promises release from last use, not before the suspension,
    /// so an unoptimized build may still carry the manager across the
    /// hang: a step wedging that family relies on the drain, never on
    /// the ordering. A held FETCH pins less still: its belt rode
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
            completion(nil)
        case .fails(let error):
            completion(error)
        case .succeedsAfter(let seconds):
            // The completion is `@Sendable` and nothing else is
            // captured, so the delay carries no reference to this
            // object and cannot outlive it into a data race.
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { completion(nil) }
        case .hangs:
            heldCompletions.append(completion)
        }
    }

    func loadPreferences(completion: @escaping @Sendable (Error?) -> Void) { completion(nil) }

    func removePreferences(completion: @escaping @Sendable (Error?) -> Void) {
        removeCount += 1
        switch removeAnswer {
        case .succeeds:
            completion(nil)
        case .fails(let error):
            completion(error)
        case .succeedsAfter(let seconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { completion(nil) }
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
