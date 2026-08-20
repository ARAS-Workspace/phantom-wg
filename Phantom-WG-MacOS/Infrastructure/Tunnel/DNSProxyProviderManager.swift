import Foundation
import NetworkExtension
import os.log

/// Wraps `NEDNSProxyManager`. Owns preference-layer lifecycle only —
/// runtime config updates to the running provider go through the
/// App's `DNSProxyDaemonClient` XPC channel. Every save is preceded
/// by `loadFromPreferences` to avoid `NEConfigurationManager Code 5:
/// configuration is stale`.
@Observable
@MainActor
class DNSProxyProviderManager {

    private static let providerBundleID = "com.remrearas.Phantom-WG-MacOS.PhantomDNSProxy"
    private static let localizedDescription = "Phantom-WG DNSProxy"

    private let log = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS",
        category: "dns-proxy-manager"
    )

    // MARK: - Load

    /// Preference-layer warm-up: primes the shared manager's cache with a
    /// first `loadFromPreferences` before the first enable/disable save
    /// reaches it. Named for boot because that is where it is called,
    /// not because the coordinator reads enable state from here — it
    /// reads that from the store.
    func load() async {
        try? await NEDNSProxyManager.shared().loadFromPreferences()
    }

    // MARK: - Enable / Disable

    func enable(with configuration: SplitTunnelingConfiguration) async throws {
        let mgr = NEDNSProxyManager.shared()
        try await mgr.loadFromPreferences()

        let proto = NEDNSProxyProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = "127.0.0.1"

        var packedBytes = 0
        do {
            let data = try JSONEncoder().encode(configuration)
            proto.providerConfiguration = ["split_config": data]
            packedBytes = data.count
        } catch {
            os_log("enable: encode FAILED — %{public}@",
                   log: log, type: .error, "\(error)")
        }

        os_log("enable: packing apps=%{public}d bytes=%{public}d",
               log: log, type: .default, configuration.apps.count, packedBytes)

        mgr.providerProtocol = proto
        mgr.localizedDescription = Self.localizedDescription
        mgr.isEnabled = true

        try await mgr.saveToPreferences()
        try await mgr.loadFromPreferences()

        if let reloaded = mgr.providerProtocol {
            let dict = reloaded.providerConfiguration ?? [:]
            let dataSize = (dict["split_config"] as? Data)?.count ?? -1
            os_log("enable: post-reload split_config bytes=%{public}d isEnabled=%{public}@",
                   log: log, type: .default,
                   dataSize, mgr.isEnabled ? "true" : "false")
        }
    }

    func disable() async throws {
        let mgr = NEDNSProxyManager.shared()
        try await mgr.loadFromPreferences()
        guard mgr.isEnabled else { return }
        mgr.isEnabled = false
        try await mgr.saveToPreferences()
    }

    // MARK: - Remove

    /// Deletes the preference entry entirely — the uninstall path's
    /// counterpart to `enable()`'s save. Load-first per the stale-config
    /// rule above. Best-effort: a failure leaves an inert entry the
    /// next enable replaces wholesale.
    func remove() async {
        let mgr = NEDNSProxyManager.shared()
        try? await mgr.loadFromPreferences()
        try? await mgr.removeFromPreferences()
    }
}
