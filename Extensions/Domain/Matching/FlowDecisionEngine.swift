import Foundation

// MARK: - Flow Decision Engine

enum FlowDecisionEngine {

    static let selfSigningPrefix = "9C5SL5H7CM.com.remrearas.Phantom-WG-MacOS"

    static func isOwnProcess(signingIdentifier: String?) -> Bool {
        guard let id = signingIdentifier, !id.isEmpty else { return false }
        return id == selfSigningPrefix || id.hasPrefix(selfSigningPrefix + ".")
    }

    static func matches(signingID: String, against app: AppEntry) -> Bool {
        guard !signingID.isEmpty,
              !app.signingIdentifier.isEmpty,
              !app.bundleIdentifier.isEmpty else { return false }

        if signingID == app.signingIdentifier
            || signingID.hasPrefix(app.signingIdentifier + ".") {
            return true
        }

        let bundleID = app.bundleIdentifier
        let core = Self.withoutTeamPrefix(signingID)
        if core == bundleID || core.hasPrefix(bundleID + ".") {
            return true
        }

        return false
    }

    static func withoutTeamPrefix(_ signingID: String) -> String {
        guard let dot = signingID.firstIndex(of: ".") else { return signingID }
        let head = signingID[..<dot]
        let isTeamID = head.count == 10 && head.allSatisfy {
            $0.isASCII && ($0.isNumber || ($0.isLetter && $0.isUppercase))
        }
        return isTeamID ? String(signingID[signingID.index(after: dot)...]) : signingID
    }
}
