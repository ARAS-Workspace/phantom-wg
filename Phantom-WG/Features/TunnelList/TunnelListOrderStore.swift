import Foundation

/// The user's tunnel order, kept in the app's defaults under
/// `tunnel_list_order` as tunnel ids. Mac 2.2.1's `TunnelListOrderStore`
/// is the source.
enum TunnelListOrderStore {

    static let key = "tunnel_list_order"

    /// @witness TunnelList.theOrderIsKeptAcrossALaunch
    static func load(from defaults: UserDefaults = .standard) -> [UUID] {
        (defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }

    /// @witness TunnelList.theOrderIsKeptAcrossALaunch
    static func save(_ order: [UUID], to defaults: UserDefaults = .standard) {
        defaults.set(order.map(\.uuidString), forKey: key)
    }
}
