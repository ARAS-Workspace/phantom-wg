import Foundation

enum LogIdentity {

    static func overlapStart(previous: [String], next: [String]) -> Int? {
        guard let first = next.first else { return nil }
        for start in previous.indices where previous[start] == first {
            let length = previous.count - start
            guard length <= next.count else { continue }
            if previous[start...].elementsEqual(next[0..<length]) {
                return start
            }
        }
        return nil
    }

    static func identified(
        previous: [LogEntry],
        next: [(tag: String, text: String)],
        counter: inout Int
    ) -> [LogEntry] {
        var result: [LogEntry] = []
        result.reserveCapacity(next.count)
        var index = 0
        if let start = overlapStart(previous: previous.map(\.text), next: next.map(\.text)) {
            result.append(contentsOf: previous[start...])
            index = previous.count - start
        }
        while index < next.count {
            counter += 1
            result.append(LogEntry(id: counter, tag: next[index].tag, text: next[index].text))
            index += 1
        }
        return result
    }
}
