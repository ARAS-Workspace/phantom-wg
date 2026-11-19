import Foundation

/// The tunnel list's rules, kept apart from its views. Mac 2.2.1's
/// `TunnelListRules` is the source.
enum TunnelListRules {

    /// The tunnel the list's top section shows.
    ///
    /// @witness TunnelList.theActiveSectionShowsTheSlotHolder
    static func slotHolder<Item>(in items: [Item], status: (Item) -> TunnelStatus) -> Item? {
        items.first { status($0) != .inactive }
    }
}
