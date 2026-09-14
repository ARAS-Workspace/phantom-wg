import Foundation

@objc public protocol ProxyConfigDaemonProtocol {

    func applyConfig(_ data: Data, reply: @escaping (Bool) -> Void)

    func fetchLogs(reply: @escaping (Data?) -> Void)

    func clearLogs(reply: @escaping (Bool) -> Void)

    func fetchIdentity(reply: @escaping (String) -> Void)
}

public enum ProxyConfigService {
    public static let dnsProxy = "group.com.artek.phantom-wg-macos.dnsproxy"
    public static let splitTunnel = "group.com.artek.phantom-wg-macos.splittunnel"
}
