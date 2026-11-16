import CryptoKit
import Foundation

extension WireGuardKey {

    var derivedPublicKey: WireGuardKey? {
        guard let raw = Data(base64Encoded: base64),
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
            return nil
        }
        return try? WireGuardKey(parsing: privateKey.publicKey.rawRepresentation.base64EncodedString())
    }
}
