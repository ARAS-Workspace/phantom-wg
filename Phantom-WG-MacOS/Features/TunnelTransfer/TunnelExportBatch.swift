import Foundation

enum TunnelExportBatch {

    static let defaultFileName = "phantom-wg-export.zip"

    struct Listed {
        let id: UUID
        let name: String
    }

    struct Plan {
        let files: [(path: String, data: Data)]
        let unread: [String]
    }

    static func plan(listed: [Listed], payloads: [TunnelConfig]) -> Plan {
        let byID = Dictionary(payloads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var used: Set<String> = []
        var files: [(path: String, data: Data)] = []
        var unread: [String] = []
        for tunnel in listed.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            guard let config = byID[tunnel.id] else {
                unread.append(tunnel.name)
                continue
            }
            let path = uniquePath(TunnelConfFile.fileName(for: config.name), used: &used)
            files.append((path, TunnelConfFile.data(config.asConfString())))
        }
        return Plan(files: files, unread: unread)
    }

    private static func uniquePath(_ fileName: String, used: inout Set<String>) -> String {
        let base = String(fileName.dropLast(".conf".count))
        var candidate = fileName
        var number = 2
        while used.contains(candidate.lowercased()) {
            candidate = "\(base) \(number).conf"
            number += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}
