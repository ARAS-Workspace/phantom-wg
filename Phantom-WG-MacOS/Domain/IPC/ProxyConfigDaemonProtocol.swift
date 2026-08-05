import Foundation

/// XPC interface shared by the lazy-spawned proxy system extensions
/// (PhantomDNSProxy, PhantomSplitTunnel). The host app pushes split-
/// tunneling configuration and drains the extension's log ring buffer
/// over this channel. Each extension vends its own Mach service; the
/// wire contract is identical.
@objc public protocol ProxyConfigDaemonProtocol {

    /// JSON-encoded `SplitTunnelingConfiguration` push from the host
    /// app. The daemon buffers it when the provider has not spawned
    /// yet, then replays it at `attach`.
    func applyConfig(_ data: Data, reply: @escaping (Bool) -> Void)

    /// Newline-joined UTF-8 snapshot of the extension's log ring
    /// buffer, or `nil` when empty.
    func fetchLogs(reply: @escaping (Data?) -> Void)

    /// Manual flush of the ring buffer.
    func clearLogs(reply: @escaping (Bool) -> Void)

    /// The extension's build identity (`ExtensionIdentity.current`).
    /// The extension gate reads it to decide whether an activation —
    /// a replacement that kills the extension's running sessions — is
    /// needed at all.
    func fetchIdentity(reply: @escaping (String) -> Void)
}

/// Mach service names, one per proxy extension. Each must literally
/// start with an `application-groups` entitlement entry shared by the
/// extension and the app.
public enum ProxyConfigService {
    public static let dnsProxy = "group.com.remrearas.phantom-wg-macos.dnsproxy"
    public static let splitTunnel = "group.com.remrearas.phantom-wg-macos.splittunnel"
}
