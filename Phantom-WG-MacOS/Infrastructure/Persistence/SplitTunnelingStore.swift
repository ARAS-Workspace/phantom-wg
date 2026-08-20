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

    /// The last live push and the count of pushes before it. The
    /// counter is what makes a REPEAT of the same verdict reach the
    /// screen: without it an identical second failure would leave the
    /// value unchanged, `onChange` would not fire, and the second
    /// failure would be silent exactly like every failure was before.
    struct PushReport: Equatable {
        let outcome: SplitTunnelingSessionCoordinator.ReconfigureOutcome
        let sequence: Int
    }

    /// Nil until the first live push. Only edits made while the session
    /// is running produce one; `.notRunning` is recorded too, because
    /// an edit that never reached the extensions is a fact the screen
    /// may want, not an error to hide.
    private(set) var lastPush: PushReport?
    @ObservationIgnored private var pushSequence = 0

    /// What the last stop could not take down, by display name. Empty
    /// when it landed.
    ///
    /// Persistent by design, and deliberately NOT a retry trigger. The
    /// user asked for a stop and the request went out; what failed is
    /// the system accepting the write. A retry loop here would fight the
    /// same refusal on a timer with nothing new to offer, so the row
    /// says what is still registered and lets the user decide. It clears
    /// when a start re-registers both extensions — until then the entry
    /// really is still there, and a row that disappeared on its own
    /// would be the lie this campaign spent itself removing.
    private(set) var stopResidue: [String] = []

    /// True while the most recent push that actually REACHED for the
    /// extensions failed to land on both. Separate from `lastPush`
    /// because that value also carries `.notRunning`, and an edit made
    /// while the feature is stopped would otherwise clear a warning
    /// about extensions still running the wrong list — a report that
    /// settles nothing is not a report that the trouble is over.
    private(set) var lastPushFailed = false

    /// Records what a stop left behind.
    ///
    /// Only `.landed` clears the row, and `.alreadyStopped` deliberately
    /// does not: a stop that found the feature already down asked
    /// nothing of either extension, so it has no standing to say the
    /// residue is gone. `reset()` sends exactly that stop.
    func recordStop(_ outcome: SplitTunnelingSessionCoordinator.StopOutcome) {
        switch outcome {
        case .residue(let names): stopResidue = names
        case .landed: stopResidue = []
        case .alreadyStopped: break
        }
    }

    /// Records a push made outside the store's own mutation path —
    /// `boot`'s realign is one, and its verdict used to end in os_log
    /// while its comment claimed otherwise.
    func recordPush(_ outcome: SplitTunnelingSessionCoordinator.ReconfigureOutcome) {
        pushSequence += 1
        lastPush = PushReport(outcome: outcome, sequence: pushSequence)
        if case .pushed = outcome { lastPushFailed = !outcome.bothLanded }
    }

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
        Task { [weak self, weak sessionCoordinator] in
            if enabled {
                do {
                    try await sessionCoordinator?.start(with: snapshot)
                    // Both extensions are registered again, so whatever an
                    // earlier stop failed to take down is no longer there.
                    self?.stopResidue = []
                } catch {
                    // The start rolls itself back and reports there. An
                    // earlier stop's residue is left standing on purpose:
                    // nothing re-registered, so the row is still true.
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
        Task { [weak self, weak sessionCoordinator] in
            if let outcome = await sessionCoordinator?.stop() {
                self?.recordStop(outcome)
            }
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
        Task { [weak self, weak sessionCoordinator] in
            guard let outcome = await sessionCoordinator?.reconfigure(with: snapshot),
                  let self else { return }
            self.recordPush(outcome)
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
            // The one mutation path that used to stop at disk. Every
            // other writer that CHANGES the app list or the interface
            // reloads — `reset` and `purgeForUninstall` do not, and
            // deliberately: one drives `stop()` and the other is tearing
            // the feature down. Skipping it here meant a
            // dropped entry left the screen and the file while both
            // extensions kept bypassing that signing identity — the
            // user reads "no longer routed outside the tunnel" and the
            // traffic keeps leaving through the physical interface.
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
