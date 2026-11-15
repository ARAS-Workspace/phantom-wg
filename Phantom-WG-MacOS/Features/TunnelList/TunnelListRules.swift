import CoreGraphics

enum TunnelListRules {

    static let rowHeight: CGFloat = 56

    static func slotHolder<Item>(in items: [Item], status: (Item) -> TunnelStatus) -> Item? {
        items
            .compactMap { item in status(item).slotRank.map { (rank: $0, item: item) } }
            .min { $0.rank < $1.rank }?
            .item
    }
}

extension TunnelStatus {
    var slotRank: Int? {
        switch self {
        case .active, .reasserting, .activating: return 0
        case .deactivating: return 1
        case .waiting: return 2
        case .inactive, .unknown: return nil
        }
    }
}
