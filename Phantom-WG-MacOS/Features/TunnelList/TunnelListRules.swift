import Foundation

enum TunnelListRules {

    static let rowHeight: CGFloat = 56
    static let dividerHeight: CGFloat = 1
    static let dividerInset: CGFloat = 10
    static let pagerHeight: CGFloat = 28
    static let pagerGap: CGFloat = 8

    static func slotHolder<Item>(in items: [Item], status: (Item) -> TunnelStatus) -> Item? {
        items
            .compactMap { item in status(item).slotRank.map { (rank: $0, item: item) } }
            .min { $0.rank < $1.rank }?
            .item
    }

    // MARK: - Search

    static func matches(_ name: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || folded(name).localizedStandardContains(folded(trimmed))
    }

    private static func folded(_ text: String) -> String {
        text.replacingOccurrences(of: "ı", with: "i")
    }

    // MARK: - Paging

    static func rowsPerPage(height: CGFloat) -> Int {
        max(1, Int((height + dividerHeight) / (rowHeight + dividerHeight)))
    }

    static func pageCount(itemCount: Int, perPage: Int) -> Int {
        let perPage = max(1, perPage)
        return max(1, (itemCount + perPage - 1) / perPage)
    }

    static func clampedPage(_ page: Int, itemCount: Int, perPage: Int) -> Int {
        min(max(0, page), pageCount(itemCount: itemCount, perPage: perPage) - 1)
    }

    static func page<Item>(_ items: [Item], index: Int, perPage: Int) -> ArraySlice<Item> {
        let perPage = max(1, perPage)
        let start = min(clampedPage(index, itemCount: items.count, perPage: perPage) * perPage, items.count)
        return items[start..<min(start + perPage, items.count)]
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
