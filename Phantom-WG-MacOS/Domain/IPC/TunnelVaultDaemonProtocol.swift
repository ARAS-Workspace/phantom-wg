import Foundation

@objc public protocol TunnelVaultDaemonProtocol {

    func storeVault(_ payload: Data, id: String, reply: @escaping (Bool) -> Void)

    func fetchVault(id: String, reply: @escaping (Data?, Bool) -> Void)

    func deleteVault(id: String, reply: @escaping (Bool) -> Void)

    func fetchAllVaults(reply: @escaping ([Data]?) -> Void)

    func purgeVault(reply: @escaping (Bool) -> Void)

    func pingIdentity(reply: @escaping (String, Bool, Int) -> Void)

}

public enum TunnelVaultService {
    public static let machServiceName = "group.com.remrearas.phantom-wg-macos.tunnelvault"
}
