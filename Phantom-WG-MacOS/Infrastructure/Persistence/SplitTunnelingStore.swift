import Foundation
import AppKit
import Observation

/// Main-app source of truth for the split-tunnelling configuration.
/// Persists as JSON inside the App Group container; the extensions
/// receive the same blob through `providerConfiguration["split_config"]`
/// and never read this file directly.
@Observable
@MainActor
final class SplitTunnelingStore {

    // MARK: - State

    private(set) var configuration: SplitTunnelingConfiguration

    /// Wired at app startup. Every lifecycle and config mutation is
    /// delegated through the coordinator. Weak to avoid cycle.
    @ObservationIgnored weak var sessionCoordinator: SplitTunnelingSessionCoordinator?

    // MARK: - Init

    /// Production: no argument — persists to the App Group container.
    /// Previews: pass `fileURL` to keep the persist/load cycle in an
    /// isolated temp file so canvas interactions never touch real config.
    init(fileURL: URL? = nil) {
        self.fileURLOverride = fileURL
        self.configuration = Self.loadFromDisk(fileURL: fileURL) ?? .default
    }

    @ObservationIgnored private let fileURLOverride: URL?

    private var effectiveFileURL: URL? {
        fileURLOverride ?? SharedConstants.splitTunnelingConfigurationFileURL
    }

    // MARK: - Mutation

    /// Master gate. Persists immediately and delegates the lifecycle
    /// transition to the coordinator. The app list survives both
    /// directions so re-enabling restores the previous state.
    func setEnabled(_ enabled: Bool) {
        configuration.isEnabled = enabled
        persist()
        let snapshot = configuration
        Task { [weak sessionCoordinator] in
            if enabled {
                try? await sessionCoordinator?.start(with: snapshot)
            } else {
                await sessionCoordinator?.stop()
            }
        }
    }

    func setInterfaceSelection(_ selection: InterfaceSelection) {
        configuration.interfaceSelection = selection
        persist()
        scheduleReload()
    }

    /// Append a validated entry. Caller is expected to dedupe; any
    /// duplicate that slips through returns `false`.
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

    /// Clear every field back to first-run baseline. The confirmation
    /// promises "disable the feature", so a running session is stopped
    /// the same way the master toggle does it — no config push: a
    /// stopping session has nothing to apply, and the next start reads
    /// the baseline from storage anyway.
    func reset() {
        configuration = .default
        persist()
        Task { [weak sessionCoordinator] in
            await sessionCoordinator?.stop()
        }
    }

    // MARK: - System DNS Resolver Toggle

    /// `true` when the synthetic mDNSResponder pair is in the app
    /// list. List membership IS the toggle state.
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

    /// Routes config changes through the coordinator's
    /// `reconfigure(with:)`, which pushes the payload to both
    /// extensions over their XPC config daemons. No-op when
    /// stopped — edits stick in storage and apply on next start.
    private func scheduleReload() {
        let snapshot = configuration
        Task { [weak sessionCoordinator] in
            await sessionCoordinator?.reconfigure(with: snapshot)
        }
    }

    // MARK: - Reconcile

    /// Drops entries whose bundle identifier no longer resolves via
    /// LaunchServices; refreshes `lastKnownPath` + `displayName` for
    /// survivors. Synthetic entries (mDNSResponder pair) bypass the
    /// LaunchServices check — they identify system daemons that
    /// LaunchServices does not catalog as applications. Called on
    /// every sheet open.
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

        // A missing file is a legitimate first run — fall back to
        // `.default` quietly.
        guard let data = try? Data(contentsOf: url) else { return nil }

        if let config = try? JSONDecoder().decode(SplitTunnelingConfiguration.self, from: data) {
            return config
        }

        // The file exists but does not decode (corruption, a schema
        // change). Falling straight through to `.default` would let the
        // next persist() overwrite the user's real app list with the
        // baseline. Move the bad file aside so it stays recoverable,
        // then start from `.default`.
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
