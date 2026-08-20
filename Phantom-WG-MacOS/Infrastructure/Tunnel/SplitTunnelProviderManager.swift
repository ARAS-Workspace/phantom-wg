import Foundation
import NetworkExtension

/// Wraps `NETransparentProxyManager`. Owns the preference entry
/// lifecycle and mirrors the session's `NEVPNStatus`; runtime config
/// and log RPCs go through `SplitTunnelDaemonClient` instead.
@Observable
@MainActor
class SplitTunnelProviderManager {

    enum SessionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case disconnecting
        case invalid
    }

    var sessionStatus: SessionStatus = .disconnected

    @ObservationIgnored private var manager: NETransparentProxyManager?
    @ObservationIgnored private var statusObserver: NSObjectProtocol?

    private static let providerBundleID = "com.remrearas.Phantom-WG-MacOS.PhantomSplitTunnel"
    private static let localizedDescription = "Phantom-WG Split-Tunnel"

    // MARK: - Load

    /// Finds the existing preference entry, or falls back to a fresh
    /// in-memory manager — the entry itself is first persisted by
    /// `enable()`'s save. Production caller is the session
    /// coordinator's `boot(freshConfig:)`.
    func load() async {
        do {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            manager = managers.first ?? NETransparentProxyManager()
            attachStatusObserver()
            refreshSessionStatus()
        } catch {
            // load is non-fatal, but nothing in-process retries it:
            // enable() just throws ManagerError.notLoaded until the
            // next boot() pass (app relaunch) runs load again.
        }
    }

    // MARK: - Enable / Disable

    func enable(with configuration: SplitTunnelingConfiguration) async throws {
        guard let manager else {
            throw ManagerError.notLoaded
        }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = "127.0.0.1"

        // Throws rather than falling through, and the difference is the
        // user's list. A `proto` with no `providerConfiguration` REPLACES
        // the one on disk, so the silent path did not leave a stale blob
        // — it erased the blob and the extension came up on `.default`.
        // That fails in the safe direction (an empty list bypasses
        // nothing) but the user's configured bypasses stop working with
        // nothing said anywhere. `persistConfiguration` below already
        // throws for exactly this; the two writers now agree.
        //
        // `DNSProxyProviderManager.enable` keeps its log-and-continue
        // shape on purpose: it is not silent, and turning it into a throw
        // would fail a start on a path this Codable cannot reach.
        guard let data = try? JSONEncoder().encode(configuration) else {
            throw ManagerError.blobNotEncodable
        }
        proto.providerConfiguration = ["split_config": data]

        manager.protocolConfiguration = proto
        manager.localizedDescription = Self.localizedDescription
        manager.isEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        try manager.connection.startVPNTunnel()
    }

    /// Refreshes the persisted bootstrap blob WITHOUT touching the
    /// session — the half of `enable` that a live config change needs.
    ///
    /// `enable` cannot serve this: its last line is `startVPNTunnel()`,
    /// so calling it on every edit would restart the session the edit
    /// was meant to reconfigure. And the blob is not cosmetic. It is
    /// the ONLY thing an extension reads when the OS respawns it
    /// without the app in the loop, so leaving it at whatever was
    /// current during the last `start` means a respawned extension
    /// bypasses apps the user has since removed and ignores the ones
    /// they added — the asymmetric routing this architecture exists to
    /// prevent, arriving through the control plane.
    ///
    /// Three deliberate narrowings, because this writes to the
    /// preference layer under a running session:
    ///
    /// 1. It loads first. Saving a manager whose cache predates
    ///    another writer earns `NEConfigurationManager Code 5:
    ///    configuration is stale`, which is why the DNS manager's own
    ///    doc states the same rule for every save it makes.
    /// 2. It writes only when the encoded blob actually DIFFERS from
    ///    the one on disk. A real edit always differs; what this skips
    ///    is the repeat of an identical payload — a boot realign over an
    ///    unchanged list, or two pushes of the same bytes — where a
    ///    preference write under a live session buys nothing.
    /// 3. It refuses to write to a disabled entry. `isEnabled` is read
    ///    back from disk, not assumed, so a persist racing a `disable`
    ///    cannot resurrect the entry the stop just switched off.
    func persistConfiguration(_ configuration: SplitTunnelingConfiguration) async throws {
        guard let manager else {
            throw ManagerError.notLoaded
        }
        try await manager.loadFromPreferences()
        guard manager.isEnabled else { return }
        guard let data = try? JSONEncoder().encode(configuration) else {
            throw ManagerError.blobNotEncodable
        }

        let existing = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?["split_config"] as? Data
        if existing == data { return }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = "127.0.0.1"
        proto.providerConfiguration = ["split_config": data]

        manager.protocolConfiguration = proto
        manager.localizedDescription = Self.localizedDescription
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }

    /// Takes the entry down and reports whether the system accepted it.
    ///
    /// The save used to be a `try?`, which made the refusal structurally
    /// invisible: the function is declared `throws` and its only throwing
    /// call swallowed its own error, so every `catch` a caller wrote
    /// around it was dead code — including the one in the start
    /// rollback, whose log line then announced "SplitTunnel down" over an
    /// entry still enabled on disk. `stopVPNTunnel()` and the flag are
    /// left where they are on a refusal: the session really was asked to
    /// stop, and the caller's job is to say what did not persist, not to
    /// pretend the request was never made.
    func disable() async throws {
        guard let manager else { return }
        manager.connection.stopVPNTunnel()
        manager.isEnabled = false
        try await manager.saveToPreferences()
    }

    // MARK: - Remove

    /// Deletes the preference entry entirely — the uninstall path's
    /// counterpart to `enable()`'s save. Loads first when needed so a
    /// cold call still finds the entry. Best-effort: a failure leaves
    /// an inert entry the next enable replaces wholesale.
    func remove() async {
        if manager == nil { await load() }
        guard let manager else { return }
        try? await manager.removeFromPreferences()
        self.manager = nil
        sessionStatus = .disconnected
    }

    // MARK: - Observation

    private func attachStatusObserver() {
        if let existing = statusObserver {
            NotificationCenter.default.removeObserver(existing)
            statusObserver = nil
        }
        guard let manager else { return }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSessionStatus()
            }
        }
    }

    private func refreshSessionStatus() {
        guard let manager else {
            sessionStatus = .disconnected
            return
        }
        switch manager.connection.status {
        case .connected:     sessionStatus = .connected
        case .connecting, .reasserting: sessionStatus = .connecting
        case .disconnecting: sessionStatus = .disconnecting
        case .disconnected:  sessionStatus = .disconnected
        case .invalid:       sessionStatus = .invalid
        @unknown default:    sessionStatus = .invalid
        }
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Errors

    enum ManagerError: LocalizedError {
        case notLoaded
        /// The configuration would not encode, so there is no blob to
        /// write. Its own case rather than a silent return, and now for
        /// two callers with different stakes: `persistConfiguration`
        /// reports whether the bootstrap blob is current, where a
        /// failure to build one is not the same as nothing to do; and
        /// `enable` would otherwise hand the system a protocol object
        /// with no configuration at all, replacing the blob on disk with
        /// nothing and bringing the extension up on an empty list.
        case blobNotEncodable

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "Split-tunnel provider manager not loaded."
            case .blobNotEncodable:
                return "Split-tunnel configuration could not be encoded."
            }
        }
    }
}
