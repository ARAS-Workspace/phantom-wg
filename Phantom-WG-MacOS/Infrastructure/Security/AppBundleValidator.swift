import Foundation
import Security

enum AppBundleValidator {

    // MARK: - Error

    enum ValidationError: Error, Equatable {
        case notABundle
        case noBundleIdentifier
        case notSigned
    }

    // MARK: - Entry Point

    static func validate(url: URL) -> Result<AppEntry, ValidationError> {
        guard let bundle = Bundle(url: url) else {
            return .failure(.notABundle)
        }
        guard let bundleIdentifier = bundle.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return .failure(.noBundleIdentifier)
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return .failure(.notSigned)
        }

        var rawInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInfo
        )
        guard infoStatus == errSecSuccess,
              let info = rawInfo as? [String: Any] else {
            return .failure(.notSigned)
        }

        guard let csIdentifier = info["identifier"] as? String, !csIdentifier.isEmpty else {
            return .failure(.notSigned)
        }

        let signingIdentifier: String
        if let teamID = info["teamid"] as? String, !teamID.isEmpty {
            signingIdentifier = "\(teamID).\(csIdentifier)"
        } else {
            signingIdentifier = csIdentifier
        }

        let teamName = extractTeamName(from: info)
        let displayName = resolveDisplayName(bundle: bundle, url: url)

        return .success(AppEntry(
            signingIdentifier: signingIdentifier,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            teamName: teamName,
            lastKnownPath: url.path
        ))
    }

    // MARK: - Helpers

    private static func extractTeamName(from info: [String: Any]) -> String? {
        guard let certs = info["certificates"] as? [SecCertificate],
              let leaf = certs.first else {
            return nil
        }

        var commonName: CFString?
        guard SecCertificateCopyCommonName(leaf, &commonName) == errSecSuccess,
              let raw = commonName as String? else {
            return nil
        }

        var name = raw
        if let colonRange = name.range(of: ":") {
            name = String(name[colonRange.upperBound...])
        }
        if let parenRange = name.range(of: " (") {
            name = String(name[..<parenRange.lowerBound])
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolveDisplayName(bundle: Bundle, url: URL) -> String {
        if let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String, !name.isEmpty {
            return name
        }
        if let name = bundle.infoDictionary?["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
