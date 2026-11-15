import Foundation
import UniformTypeIdentifiers

enum TunnelConfFile {

    static let contentType = UTType(filenameExtension: "conf") ?? .plainText

    static func fileName(for tunnelName: String) -> String {
        let base = tunnelName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(base).conf"
    }

    static func write(_ contents: String, to url: URL) throws {
        try Data((contents + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
