import Foundation

enum TunnelListOrderStore {

    static let key = "tunnel_list_order"

    static func load(from defaults: UserDefaults = .standard) -> [UUID] {
        (defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }

    static func save(_ order: [UUID], to defaults: UserDefaults = .standard) {
        defaults.set(order.map(\.uuidString), forKey: key)
    }
}
