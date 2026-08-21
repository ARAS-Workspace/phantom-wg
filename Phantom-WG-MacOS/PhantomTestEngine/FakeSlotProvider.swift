// ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
// ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
// ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
// ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
// ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
// ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
//
// Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
// Licensed under AGPL-3.0 - see LICENSE file for details
// WireGuard® is a registered trademark of Jason A. Donenfeld.
//
// Test Engine: Fake Slot Provider
//
// A `TunnelProviding` that answers like the system without touching it.
// Every workflow that needs a tunnel row without a real NE session builds
// one from this.
//
// What it can be told to do:
//
//   saveAnswer / removeAnswer / loadAnswer   succeed now, succeed after a
//                                            delay, refuse, or hold the
//                                            completion and never answer
//   startAnswer                              succeed or throw
//   resetAnswer                              any opcode-3 reply shape,
//                                            including ones a deployed
//                                            extension cannot produce
//   disconnectAnswer                         what the last-error probe says
//
// A held completion is released on demand by `releaseHeldCompletions()`,
// which is how a step measures a caller that is waiting on a save the
// system never answered.
//
// `drive(_:)` sets the status and posts `.NEVPNStatusDidChange` with
// itself as the object — this fake stands in for both the manager and its
// session, so the two roles the system keeps apart are one object here;
// `matchesNotification`
// answers only for notifications carrying THIS instance, so a driven
// notification cannot be picked up by a real tunnel. `setStatusSilently`
// moves the status without publishing, for arrangements that must not wake
// an observer. `arrangeArmed()` puts the slot in the on-demand armed shape
// — enabled, stored as enabled, carrying a single connect-on-any rule — so
// a step can start from a recovery arrangement instead of building one.
//
// It counts saves, loads, starts, stops, removes and provider messages,
// and records when the last save was issued; the last-error probe is
// answered but not counted.
//
// What it deliberately does NOT fake: the vault (`FaultVaultClient` owns
// that) and the extension gate (`FakeExtensionSubmitter` owns that).
//
// `MintedProviderLedger` at the bottom records the providers a factory
// minted during a run, so a step can assert on rows the app created rather
// than on rows the step handed it.

#if DEBUG
import Foundation
import NetworkExtension

final class FakeSlotProvider: TunnelProviding {

    // MARK: - Injectable answers

    enum SaveAnswer {
        case succeeds
        case fails(NSError)
        case succeedsAfter(seconds: Double)
        case hangs
    }

    enum DisconnectAnswer {
        case none
        case record(NSError)
        case recordAfter(seconds: Double, NSError)
        case never
    }

    enum StartAnswer {
        case succeeds
        case fails(NSError)
    }

    enum ResetAnswer: Sendable {
        case status(TunnelResetReply)
        case rawStatus(UInt8)
        case legacy
        case silent
    }

    var saveAnswer: SaveAnswer = .succeeds
    var removeAnswer: SaveAnswer = .succeeds
    var loadAnswer: SaveAnswer = .succeeds
    var startAnswer: StartAnswer = .succeeds
    var resetAnswer: ResetAnswer = .status(.rebuilt)
    var providerMessageCount = 0
    var disconnectAnswer: DisconnectAnswer = .none

    private var heldCompletions: [@Sendable (Error?) -> Void] = []

    // MARK: - Observed state

    var localizedDescription: String?
    var isEnabled = false
    private(set) var identity: TunnelIdentity?
    var tunnelIdentity: TunnelIdentity? { identity }
    func configure(with identity: TunnelIdentity) { self.identity = identity }
    var isOnDemandEnabled = false
    private(set) var storedOnDemand = false
    private(set) var entryExists: Bool
    private(set) var storedDescription: String?
    private(set) var storedIdentity: TunnelIdentity?
    var onDemandRules: [NEOnDemandRule]?
    private(set) var connectionStatus: NEVPNStatus
    private(set) var saveCount = 0
    private(set) var lastSaveIssuedAt: Date?
    private(set) var loadCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var removeCount = 0

    init(name: String?, identity: TunnelIdentity?, status: NEVPNStatus, entryExists: Bool = true) {
        self.localizedDescription = name
        self.identity = identity
        self.storedDescription = name
        self.storedIdentity = identity
        self.connectionStatus = status
        self.entryExists = entryExists
    }

    // MARK: - Driving the manager

    func drive(_ status: NEVPNStatus) {
        connectionStatus = status
        NotificationCenter.default.post(name: .NEVPNStatusDidChange, object: self)
    }

    func setStatusSilently(_ status: NEVPNStatus) {
        connectionStatus = status
    }

    func arrangeArmed() {
        isOnDemandEnabled = true
        storedOnDemand = true
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        onDemandRules = [rule]
    }

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
        if case .fails(let error) = startAnswer { throw error }
    }

    func stopTunnel() { stopCount += 1 }

    func sendProviderMessage(_ data: Data, responseHandler: @escaping @Sendable (Data?) -> Void) throws {
        providerMessageCount += 1
        guard data.first == 3 else {
            responseHandler(nil)
            return
        }
        switch resetAnswer {
        case .status(let reply):
            responseHandler(Data([3, reply.rawValue]))
        case .rawStatus(let raw):
            responseHandler(Data([3, raw]))
        case .legacy:
            responseHandler(Data([3]))
        case .silent:
            break
        }
    }

    func savePreferences(completion: @escaping @Sendable (Error?) -> Void) {
        saveCount += 1
        lastSaveIssuedAt = Date()
        switch saveAnswer {
        case .succeeds:
            storedOnDemand = isOnDemandEnabled
            storedDescription = localizedDescription
            storedIdentity = identity
            entryExists = true
            completion(nil)
        case .fails(let error):
            completion(error)
        case .succeedsAfter(let seconds):
            let landing = isOnDemandEnabled
            let landingDescription = localizedDescription
            let landingIdentity = identity
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.storedOnDemand = landing
                self?.storedDescription = landingDescription
                self?.storedIdentity = landingIdentity
                self?.entryExists = true
                completion(nil)
            }
        case .hangs:
            heldCompletions.append(completion)
        }
    }

    func loadPreferences(completion: @escaping @Sendable (Error?) -> Void) {
        loadCount += 1
        switch loadAnswer {
        case .succeeds:
            isOnDemandEnabled = storedOnDemand
            localizedDescription = storedDescription
            identity = storedIdentity
            completion(nil)
        case .fails(let error):
            completion(error)
        case .succeedsAfter(let seconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                if let self {
                    self.isOnDemandEnabled = self.storedOnDemand
                    self.localizedDescription = self.storedDescription
                    self.identity = self.storedIdentity
                }
                completion(nil)
            }
        case .hangs:
            heldCompletions.append(completion)
        }
    }

    func removePreferences(completion: @escaping @Sendable (Error?) -> Void) {
        removeCount += 1
        switch removeAnswer {
        case .succeeds:
            storedOnDemand = false
            entryExists = false
            completion(nil)
        case .fails(let error):
            completion(error)
        case .succeedsAfter(let seconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.storedOnDemand = false
                self?.entryExists = false
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

final class MintedProviderLedger {

    var saveAnswer: FakeSlotProvider.SaveAnswer = .succeeds
    var loadAnswer: FakeSlotProvider.SaveAnswer = .succeeds

    private(set) var providers: [FakeSlotProvider] = []

    var last: FakeSlotProvider? { providers.last }

    func record(_ provider: FakeSlotProvider) { providers.append(provider) }
}

struct FakeSlotFactory: TunnelProviderFactory {
    let canned: [TunnelProviding]

    let minted = MintedProviderLedger()

    func makeProvider() -> TunnelProviding {
        let provider = FakeSlotProvider(name: nil, identity: nil, status: .invalid, entryExists: false)
        provider.saveAnswer = minted.saveAnswer
        provider.loadAnswer = minted.loadAnswer
        minted.record(provider)
        return provider
    }

    func loadAllFromPreferences() async throws -> [TunnelProviding] {
        let all: [TunnelProviding] = canned + minted.providers
        return all.filter { ($0 as? FakeSlotProvider)?.entryExists ?? true }
    }
}
#endif
