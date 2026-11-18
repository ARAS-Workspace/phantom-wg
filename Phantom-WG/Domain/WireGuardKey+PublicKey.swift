import CryptoKit
import Foundation

/// The Curve25519 public key that belongs to a private key — what the
/// tunnel detail shows in place of the private key itself. `nil` when
/// the key is not a valid Curve25519 private key.
extension WireGuardKey {

    /// @witness ConfigContract.secretlessDetail
    var derivedPublicKey: WireGuardKey? {
        guard let raw = Data(base64Encoded: base64),
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
            return nil
        }
        return try? WireGuardKey(parsing: privateKey.publicKey.rawRepresentation.base64EncodedString())
    }
}
