// Test Engine: Fake Slot Provider
//
// A `TunnelProviding` that answers like the system without touching it.
// Every workflow that needs a tunnel row without a real NE session builds
// one from this, and runs it under a `TunnelsManager` of its own, so
// nothing a step plants reaches the user's list.
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
// Like a real manager object, it keeps two copies of its configuration:
// the one the app is editing (what `configure(with:)`, the description and
// the flags write) and the one the system stored (what the last successful
// save wrote, and what a load reads back). It stores the configuration one
// of two ways:
//
//   .memory     the `TunnelConfig` itself, as previews do
//   .keychain   a real `NETunnelProviderProtocol` from the production
//               `configure(with:)` path, sealed into the app group
//               Keychain — for a step that measures what that path does
//               to the stored copy. `keychainRefs` lists every item this
//               provider ever referenced, `keychainRef` the one its
//               edited copy opens, and `sweepKeychain()` deletes them all.
//
// `drive(_:)` sets the status and posts `.NEVPNStatusDidChange` with
// itself as the object — this fake stands in for both the manager and its
// session; `matchesNotification` answers only for notifications carrying
// THIS instance, so a driven notification cannot be picked up by a real
// tunnel. `setStatusSilently` moves the status without publishing.
// `arrangeArmed()` puts the slot in the on-demand armed shape.
//
// It counts saves, loads, starts, stops, removes and provider messages,
// and records when the last save was issued.
//
// `MintedProviderLedger` records the providers a `FakeSlotFactory` minted
// during a run, so a step can assert on rows the app created rather than
// on rows the step handed it. Its `saveAnswers` names the save answer of
// one provider by the order the factory mints it, counting from 1; the
// others take `saveAnswer`.

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

    enum ResetAnswer {
        case status(TunnelResetReply)
        case rawStatus(UInt8)
        case legacy
        case silent
    }

    enum Storage {
        case memory
        case keychain
    }

    var saveAnswer: SaveAnswer = .succeeds
    var removeAnswer: SaveAnswer = .succeeds
    var loadAnswer: SaveAnswer = .succeeds
    var startAnswer: StartAnswer = .succeeds
    var resetAnswer: ResetAnswer = .status(.rebuilt)
    var disconnectAnswer: DisconnectAnswer = .none

    private var heldCompletions: [@Sendable (Error?) -> Void] = []

    // MARK: - The copy the app edits

    let storage: Storage
    var localizedDescription: String?
    var isEnabled = false
    var isOnDemandEnabled = false
    var onDemandRules: [NEOnDemandRule]?
    var protocolConfiguration: NEVPNProtocol? {
        didSet { remember(protocolConfiguration) }
    }
    private var memoryConfig: TunnelConfig?

    var tunnelConfig: TunnelConfig? {
        switch storage {
        case .memory: return memoryConfig
        case .keychain: return (protocolConfiguration as? NETunnelProviderProtocol)?.tunnelConfig
        }
    }

    func configure(with config: TunnelConfig) throws {
        switch storage {
        case .memory:
            memoryConfig = config
        case .keychain:
            let manager = NETunnelProviderManager()
            manager.protocolConfiguration = protocolConfiguration
            try manager.configure(with: config)
            protocolConfiguration = manager.protocolConfiguration
        }
    }

    var keychainRef: Data? {
        (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["keychainRef"] as? Data
    }

    // MARK: - The copy the system stored

    private(set) var entryExists: Bool
    private(set) var storedDescription: String?
    private(set) var storedEnabled = false
    private(set) var storedOnDemand = false
    private var storedMemoryConfig: TunnelConfig?
    private var storedProtocol: NEVPNProtocol?

    // MARK: - Observed state

    private(set) var connectionStatus: NEVPNStatus
    private(set) var saveCount = 0
    private(set) var lastSaveIssuedAt: Date?
    private(set) var loadCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var removeCount = 0
    private(set) var providerMessageCount = 0
    private(set) var keychainRefs: [Data] = []

    init(storage: Storage = .memory, config: TunnelConfig? = nil,
         status: NEVPNStatus = .disconnected, entryExists: Bool = true) {
        self.storage = storage
        self.connectionStatus = status
        self.entryExists = entryExists
        if let config {
            localizedDescription = config.name
            try? configure(with: config)
            commit()
        }
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
        let cancelled = NSError(domain: "TE.Fake", code: 44,
                                userInfo: [NSLocalizedDescriptionKey: "test rig released a held request"])
        for completion in held { completion(cancelled) }
        return held.count
    }

    /// Deletes every Keychain item this provider ever referenced; a
    /// `.keychain` provider's step owes this to the device it borrowed.
    func sweepKeychain() {
        for ref in keychainRefs { Keychain.deleteReference(called: ref) }
        keychainRefs.removeAll()
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
            commit()
            completion(nil)
        case .fails(let error):
            completion(error)
        case .succeedsAfter(let seconds):
            let landing = snapshot()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.commit(landing)
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
            restore()
            completion(nil)
        case .fails(let error):
            completion(error)
        case .succeedsAfter(let seconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.restore()
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

    // MARK: - Private

    private struct Snapshot {
        let description: String?
        let enabled: Bool
        let onDemand: Bool
        let memoryConfig: TunnelConfig?
        let proto: NEVPNProtocol?
    }

    private func snapshot() -> Snapshot {
        Snapshot(description: localizedDescription, enabled: isEnabled, onDemand: isOnDemandEnabled,
                 memoryConfig: memoryConfig, proto: protocolConfiguration)
    }

    private func commit(_ landing: Snapshot? = nil) {
        let state = landing ?? snapshot()
        storedDescription = state.description
        storedEnabled = state.enabled
        storedOnDemand = state.onDemand
        storedMemoryConfig = state.memoryConfig
        storedProtocol = state.proto
        entryExists = true
    }

    private func restore() {
        localizedDescription = storedDescription
        isEnabled = storedEnabled
        isOnDemandEnabled = storedOnDemand
        memoryConfig = storedMemoryConfig
        protocolConfiguration = storedProtocol
    }

    private func remember(_ proto: NEVPNProtocol?) {
        guard let ref = (proto as? NETunnelProviderProtocol)?.providerConfiguration?["keychainRef"] as? Data,
              !keychainRefs.contains(ref) else { return }
        keychainRefs.append(ref)
    }
}

final class MintedProviderLedger {

    var saveAnswer: FakeSlotProvider.SaveAnswer = .succeeds
    var saveAnswers: [Int: FakeSlotProvider.SaveAnswer] = [:]
    var loadAnswer: FakeSlotProvider.SaveAnswer = .succeeds
    var status: NEVPNStatus = .disconnected

    private(set) var providers: [FakeSlotProvider] = []

    var last: FakeSlotProvider? { providers.last }

    func record(_ provider: FakeSlotProvider) { providers.append(provider) }
}

struct FakeSlotFactory: TunnelProviderFactory {
    let canned: [TunnelProviding]
    var loadFailure: Error?

    let minted = MintedProviderLedger()

    func makeProvider() -> TunnelProviding {
        let provider = FakeSlotProvider(status: minted.status, entryExists: false)
        provider.saveAnswer = minted.saveAnswers[minted.providers.count + 1] ?? minted.saveAnswer
        provider.loadAnswer = minted.loadAnswer
        minted.record(provider)
        return provider
    }

    func loadAllFromPreferences() async throws -> [TunnelProviding] {
        if let loadFailure { throw loadFailure }
        let all: [TunnelProviding] = canned + minted.providers
        return all.filter { ($0 as? FakeSlotProvider)?.entryExists ?? true }
    }
}
#endif
