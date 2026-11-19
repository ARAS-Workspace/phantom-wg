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

    private static func folded(_ text: String) -> String {
        text.replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldingLocale)
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
