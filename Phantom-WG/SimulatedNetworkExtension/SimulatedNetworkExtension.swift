#if DEBUG && targetEnvironment(simulator)
import Foundation
import NetworkExtension
import os

/// Stands in for the part of NetworkExtension the iOS Simulator does not
/// have: the configuration store behind `nehelper`, and the system's
/// on-demand rule that brings an armed tunnel back. Debug builds on the
/// simulator reach it through `TunnelsManager.create()`; Release builds
/// do not compile this directory.
///
/// The store keeps the system's own rules: one enabled configuration per
/// app (enabling one disables, and disconnects, the others), and a
/// `NEVPNConfigurationChange` after every write. Records live in a file
/// in the app's container, so they survive a relaunch the way the
/// system's store does. The secrets stay where the app puts them — the
/// Keychain — and the file carries only the persistent reference.
///
/// Every write and every session transition is logged under the
/// `SimulatedNetworkExtension` category, so a run can be read back as a
/// timeline in Console or with `log show`.
///
/// Main thread only, like every caller in the app.
final class SimulatedNetworkExtension {

    static let shared = SimulatedNetworkExtension()

    static let log = Logger(subsystem: "com.artek.Phantom-WG", category: "SimulatedNetworkExtension")

    struct Record: Codable, Equatable {
        let id: UUID
        var localizedDescription: String?
        var isEnabled: Bool
        var isOnDemandEnabled: Bool
        var protocolConfiguration: Data?
        var onDemandRules: Data?
    }

    private(set) var records: [Record]
    private var sessions: [UUID: SimulatedSession] = [:]
    private var resumedArmedSessions = false
    private let fileURL: URL

    init(fileURL: URL = SimulatedNetworkExtension.defaultFileURL) {
        self.fileURL = fileURL
        records = Self.read(from: fileURL)
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("SimulatedNetworkExtension", isDirectory: true)
            .appendingPathComponent("preferences.json")
    }

    // MARK: - Store

    func record(_ id: UUID) -> Record? {
        records.first { $0.id == id }
    }

    func save(_ record: Record) {
        var disabled: [UUID] = []
        if record.isEnabled {
            for index in records.indices where records[index].id != record.id && records[index].isEnabled {
                records[index].isEnabled = false
                disabled.append(records[index].id)
            }
        }
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        write()
        Self.log.info("save \(Self.label(record), privacy: .public) enabled=\(record.isEnabled) onDemand=\(record.isOnDemandEnabled) disabled=\(disabled.count)")
        disabled.forEach { sessions[$0]?.stop(reason: .configurationDisabled) }
        postConfigurationChange()
    }

    func remove(_ id: UUID) {
        Self.log.info("remove \(self.record(id).map(Self.label) ?? id.uuidString, privacy: .public)")
        sessions[id]?.stop(reason: .configurationRemoved)
        records.removeAll { $0.id == id }
        write()
        postConfigurationChange()
    }

    // MARK: - Sessions

    func session(for id: UUID) -> SimulatedSession {
        if let existing = sessions[id] { return existing }
        let session = SimulatedSession(configurationID: id, system: self)
        sessions[id] = session
        return session
    }

    /// The system keeps an armed tunnel up while the app is not running.
    /// Here the system lives in the app's process, so a launch is where
    /// it comes back: every armed, enabled configuration is started once,
    /// the way on-demand would have kept it.
    func resumeArmedSessionsOnce() {
        guard !resumedArmedSessions else { return }
        resumedArmedSessions = true
        for record in records where Self.isArmed(record) {
            Self.log.info("launch resume \(Self.label(record), privacy: .public)")
            session(for: record.id).start(protocolConfiguration: Self.protocolConfiguration(of: record))
        }
    }

    /// On-demand: a session that ends while its configuration is enabled
    /// and armed is brought back. A user stop that was not preceded by a
    /// stand-down save comes back too — the same trap the real rule sets.
    func sessionDidEnd(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.onDemandDelay) { [weak self] in
            guard let self,
                  let record = self.record(id),
                  Self.isArmed(record),
                  let session = self.sessions[id],
                  session.status == .disconnected
            else { return }
            Self.log.info("on-demand restart \(Self.label(record), privacy: .public)")
            session.start(protocolConfiguration: Self.protocolConfiguration(of: record))
        }
    }

    static func label(_ record: Record) -> String {
        "\(record.localizedDescription ?? "-") [\(record.id.uuidString.prefix(8))]"
    }

    // MARK: - Archiving

    static func protocolConfiguration(of record: Record) -> NETunnelProviderProtocol? {
        guard let data = record.protocolConfiguration else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NETunnelProviderProtocol.self, from: data)
    }

    static func onDemandRules(of record: Record) -> [NEOnDemandRule]? {
        guard let data = record.onDemandRules else { return nil }
        return try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: NEOnDemandRule.self, from: data)
    }

    static func archived(_ object: NSObject?) -> Data? {
        guard let object else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: true)
    }

    private static func isArmed(_ record: Record) -> Bool {
        guard record.isEnabled, record.isOnDemandEnabled else { return false }
        return onDemandRules(of: record)?.contains { $0 is NEOnDemandRuleConnect } ?? false
    }

    private static let onDemandDelay: TimeInterval = 1.0

    // MARK: - File

    private static func read(from url: URL) -> [Record] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("Simulated NE store could not be written: \(error)")
        }
    }

    private func postConfigurationChange() {
        NotificationCenter.default.post(name: .NEVPNConfigurationChange, object: nil)
    }
}
#endif
