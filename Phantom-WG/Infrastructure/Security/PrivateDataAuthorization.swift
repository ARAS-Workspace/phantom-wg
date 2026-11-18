import Foundation
import LocalAuthentication

/// Device-owner check in front of a tunnel's private data — Face ID,
/// Touch ID, or the device passcode, whichever the device offers
/// (`.deviceOwnerAuthentication`). A device without a passcode has no
/// owner to ask, so the check passes. A cancel is `declined`; any other
/// failure carries the system's message.
enum PrivateDataAuthorization {

    enum Outcome: Equatable {
        case granted
        case declined
        case failed(String)
    }

    static func request(reason: String) async -> Outcome {
        let context = LAContext()
        var availability: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availability) else {
            if let error = availability as? LAError, error.code == .passcodeNotSet {
                return .granted
            }
            return .failed(availability?.localizedDescription ?? "")
        }
        do {
            let granted = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return granted ? .granted : .declined
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return .declined
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
