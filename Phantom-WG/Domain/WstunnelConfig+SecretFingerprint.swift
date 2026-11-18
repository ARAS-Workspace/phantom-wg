import CryptoKit
import Foundation

/// A short fingerprint of the wstunnel secret — what the tunnel detail
/// shows in place of the secret itself. HMAC-SHA256 of the secret keyed
/// by the tunnel's private key, first 8 bytes, as four groups of four
/// hex digits. `nil` for an empty secret or an undecodable key.
extension WstunnelConfig {

    /// @witness ConfigContract.secretlessDetail
    func secretFingerprint(keyedBy key: WireGuardKey) -> String? {
        guard !secret.isEmpty, let raw = Data(base64Encoded: key.base64) else {
            return nil
        }
        let code = HMAC<SHA256>.authenticationCode(for: Data(secret.utf8), using: SymmetricKey(data: raw))
        let bytes = Array(Array(code).prefix(8))
        return stride(from: 0, to: bytes.count, by: 2)
            .map { String(format: "%02x%02x", bytes[$0], bytes[$0 + 1]) }
            .joined(separator: " ")
    }
}
