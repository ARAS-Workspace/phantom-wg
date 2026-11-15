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

    // MARK: - Order

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

    static func moving(_ order: [UUID], _ item: UUID, onto target: UUID) -> [UUID] {
        guard item != target, let from = order.firstIndex(of: item), let to = order.firstIndex(of: target) else {
            return order
        }
        var result = order
        result.remove(at: from)
        result.insert(item, at: to)
        return result
    }

    static func movedToEdge(_ order: [UUID], _ item: UUID, top: Bool) -> [UUID] {
        guard order.contains(item) else { return order }
        let rest = order.filter { $0 != item }
        return top ? [item] + rest : rest + [item]
    }

    static func movedByOne(_ order: [UUID], _ item: UUID, up: Bool) -> [UUID] {
        guard let index = order.firstIndex(of: item) else { return order }
        let other = up ? index - 1 : index + 1
        guard order.indices.contains(other) else { return order }
        var result = order
        result.swapAt(index, other)
        return result
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
