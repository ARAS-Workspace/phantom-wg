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

    // MARK: - Order

    /// The list in the user's order: the tunnels the saved order names, in
    /// that order, after the ones it names not yet, which keep the list's
    /// own newest-first order. An id the list holds no longer is passed
    /// over, and an id saved twice places its tunnel once.
    ///
    /// @witness TunnelList.aSavedOrderKeepsItsRowsAndPutsNewOnesFirst
    static func ordered<Item>(_ items: [Item], saved: [UUID], id: (Item) -> UUID) -> [Item] {
        var byId: [UUID: Item] = [:]
        for item in items where byId[id(item)] == nil {
            byId[id(item)] = item
        }
        var placed = Set<UUID>()
        let kept = saved.compactMap { key -> Item? in
            guard placed.insert(key).inserted else { return nil }
            return byId[key]
        }
        return items.filter { !placed.contains(id($0)) } + kept
    }

    /// The order after a drag, as the list's move hands it: the rows at
    /// `offsets` land, in their order, before the row that stood at
    /// `destination`.
    ///
    /// @witness TunnelList.aDragLandsWhereItDrops
    static func moved(_ order: [UUID], from offsets: IndexSet, to destination: Int) -> [UUID] {
        let moving = offsets.filter { order.indices.contains($0) }.map { order[$0] }
        var rest = order.indices.filter { !offsets.contains($0) }.map { order[$0] }
        let landing = destination - offsets.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: min(max(landing, 0), rest.count))
        return rest
    }

    /// The order after one step up or down, as the accessibility actions
    /// move a row; a row at the edge stays where it is.
    ///
    /// @witness TunnelList.aDragLandsWhereItDrops
    static func movedByOne(_ order: [UUID], _ item: UUID, up: Bool) -> [UUID] {
        guard let index = order.firstIndex(of: item) else { return order }
        let other = up ? index - 1 : index + 1
        guard order.indices.contains(other) else { return order }
        var result = order
        result.swapAt(index, other)
        return result
    }

    // MARK: - Search

    /// Whether a tunnel's name holds the search query. In both, `ı` is
    /// read as `i`, then letter case and marks are folded under one fixed
    /// locale, so `ı`, `i`, `I` and `İ` read as one letter whatever the
    /// device's language; a query of spaces alone holds every name. Mac
    /// 2.2.1 reads `ı` as `i` too but compares under the device's locale,
    /// where a Turkish one pairs `I` with `ı` and `İ` with `i`.
    ///
    /// @witness TunnelList.searchFoldsCaseMarksAndTheTurkishI
    static func matches(_ name: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || folded(name).contains(folded(trimmed))
    }

    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    /// @witness TunnelList.searchFoldsCaseMarksAndTheTurkishI
    private static func folded(_ text: String) -> String {
        text.replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldingLocale)
    }
}

extension TunnelStatus {
    /// Where a status stands for the slot, lowest first; nil at rest.
    ///
    /// @witness TunnelList.theActiveSectionShowsTheSlotHolder
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
