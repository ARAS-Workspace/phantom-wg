import Foundation

/// The tunnel list's rules, kept apart from its views. Mac 2.2.1's
/// `TunnelListRules` is the source.
enum TunnelListRules {

    /// The tunnel the list's top section shows: the one holding the slot.
    /// A tunnel up, coming up or reasserting comes first, then one going
    /// down, then one queued; list order decides only between equal ranks.
    /// During a hand-off the queued tunnel waits while the occupant goes
    /// down, and the section shows the occupant until its session ends.
    ///
    /// @witness TunnelList.theActiveSectionShowsTheSlotHolder
    static func slotHolder<Item>(in items: [Item], status: (Item) -> TunnelStatus) -> Item? {
        items
            .compactMap { item in status(item).slotRank.map { (rank: $0, item: item) } }
            .min { $0.rank < $1.rank }?
            .item
    }
}

extension TunnelStatus {
    /// Where a status stands for the slot, lowest first; nil at rest.
    var slotRank: Int? {
        switch self {
        case .active, .reasserting, .activating:
            return 0
        case .deactivating:
            return 1
        case .waiting:
            return 2
        case .inactive:
            return nil
        }
    }
}
