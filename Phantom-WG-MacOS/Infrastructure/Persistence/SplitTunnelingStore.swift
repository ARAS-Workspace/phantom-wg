import Foundation
import AppKit
import Observation

@Observable
@MainActor
final class SplitTunnelingStore {

    // MARK: - State

    private(set) var configuration: SplitTunnelingConfiguration

    @ObservationIgnored weak var sessionCoordinator: SplitTunnelingSessionCoordinator?

    struct PushReport: Equatable {
        let outcome: SplitTunnelingSessionCoordinator.ReconfigureOutcome
        let sequence: Int
    }

    private(set) var lastPush: PushReport?
    @ObservationIgnored private var pushSequence = 0

    private(set) var stopResidue: [String] = []

    private(set) var lastPushFailed = false

    func recordStop(_ outcome: SplitTunnelingSessionCoordinator.StopOutcome) {
        switch outcome {
        case .residue(let names): stopResidue = names
        case .landed: stopResidue = []
        case .alreadyStopped: break
        }
    }

    func recordPush(_ outcome: SplitTunnelingSessionCoordinator.ReconfigureOutcome) {
        pushSequence += 1
        lastPush = PushReport(outcome: outcome, sequence: pushSequence)
        if case .pushed = outcome { lastPushFailed = !outcome.bothLanded }
    }

    // MARK: - Init

    init(fileURL: URL? = nil) {
        self.fileURLOverride = fileURL
        self.configuration = Self.loadFromDisk(fileURL: fileURL) ?? .default
    }

    @ObservationIgnored private let fileURLOverride: URL?

    private var effectiveFileURL: URL? {
        fileURLOverride ?? SharedConstants.splitTunnelingConfigurationFileURL
    }

    // MARK: - Mutation

    func setEnabled(_ enabled: Bool) {
        configuration.isEnabled = enabled
        persist()
        let snapshot = configuration
        Task { [weak self, weak sessionCoordinator] in
            if enabled {
                do {
                    try await sessionCoordinator?.start(with: snapshot)
                    self?.stopResidue = []
                } catch {
                }
            } else if let outcome = await sessionCoordinator?.stop() {
                self?.recordStop(outcome)
            }
        }
    }

    func setInterfaceSelection(_ selection: InterfaceSelection) {
        configuration.interfaceSelection = selection
        persist()
        scheduleReload()
    }

    @discardableResult
    func addApp(_ entry: AppEntry) -> Bool {
        guard !configuration.apps.contains(where: { $0.bundleIdentifier == entry.bundleIdentifier }) else {
            return false
        }
        configuration.apps.append(entry)
        persist()
        scheduleReload()
        return true
    }

    func removeApp(bundleIdentifier: String) {
        configuration.apps.removeAll { $0.bundleIdentifier == bundleIdentifier }
        persist()
        scheduleReload()
    }

    func reset() {
        configuration = .default
        persist()
        Task { [weak self, weak sessionCoordinator] in
            if let outcome = await sessionCoordinator?.stop() {
                self?.recordStop(outcome)
            }
        }
    }

    // MARK: - System DNS Resolver Toggle

    var isMDNSResponderEnabled: Bool {
        configuration.apps.contains(where: \.isSyntheticMDNS)
    }

    func setMDNSResponderEnabled(_ enabled: Bool) {
        guard enabled != isMDNSResponderEnabled else { return }
        if enabled {
            if !configuration.apps.contains(where: { $0.signingIdentifier == AppEntry.mDNSResponder.signingIdentifier }) {
                configuration.apps.append(.mDNSResponder)
            }
            if !configuration.apps.contains(where: { $0.signingIdentifier == AppEntry.mDNSResponderHelper.signingIdentifier }) {
                configuration.apps.append(.mDNSResponderHelper)
            }
        } else {
            configuration.apps.removeAll { $0.isSyntheticMDNS }
        }
        persist()
        scheduleReload()
    }

    // MARK: - Private

    private func scheduleReload() {
        let snapshot = configuration
        Task { [weak self, weak sessionCoordinator] in
            guard let outcome = await sessionCoordinator?.reconfigure(with: snapshot),
                  let self else { return }
            self.recordPush(outcome)
        }
    }

    // MARK: - Reconcile

    func reconcile() {
        guard !configuration.apps.isEmpty else { return }

        var survivors: [AppEntry] = []
        for entry in configuration.apps {
            if entry.isSyntheticMDNS {
                survivors.append(entry)
                continue
            }
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: entry.bundleIdentifier
            ) else {
                NSLog("[split-tunneling] reconcile: dropped '\(entry.bundleIdentifier)' (not installed)")
                continue
            }
            guard let bundle = Bundle(url: url),
                  bundle.bundleIdentifier == entry.bundleIdentifier else {
                NSLog("[split-tunneling] reconcile: dropped '\(entry.bundleIdentifier)' (path bundle ID mismatch)")
                continue
            }
            var updated = entry
            updated.lastKnownPath = url.path
            updated.displayName = Self.resolveDisplayName(bundle: bundle, url: url)
                ?? entry.displayName
            survivors.append(updated)
        }

        if survivors != configuration.apps {
            configuration.apps = survivors
            persist()
            scheduleReload()
        }
    }

    // MARK: - Persistence

    private func persist() {
        guard let url = effectiveFileURL else { return }
        do {
            let data = try JSONEncoder().encode(configuration)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[split-tunneling] persist failed: \(error)")
        }
    }

    private static func loadFromDisk(fileURL: URL?) -> SplitTunnelingConfiguration? {
        let url = fileURL ?? SharedConstants.splitTunnelingConfigurationFileURL
        guard let url else { return nil }

        guard let data = try? Data(contentsOf: url) else { return nil }

        if let config = try? JSONDecoder().decode(SplitTunnelingConfiguration.self, from: data) {
            return config
        }

        let quarantine = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: quarantine)
        do {
            try FileManager.default.moveItem(at: url, to: quarantine)
            NSLog("[split-tunneling] config \(url.lastPathComponent) failed to decode; moved to \(quarantine.lastPathComponent)")
        } catch {
            NSLog("[split-tunneling] config failed to decode and could not be quarantined: \(error)")
        }
        return nil
    }

    private static func resolveDisplayName(bundle: Bundle, url: URL) -> String? {
        if let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String, !name.isEmpty {
            return name
        }
        if let name = bundle.infoDictionary?["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
