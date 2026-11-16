import AppKit

@MainActor
enum PrivateDataGuard {

    static func grants(
        reason: String,
        authorize: (String) async -> PrivateDataAuthorization.Outcome = PrivateDataAuthorization.request,
        onFailure: (String) -> Void
    ) async -> Bool {
        switch await authorize(reason) {
        case .granted:
            if !NSApp.isActive {
                NSApp.activate()
            }
            return true
        case .declined:
            return false
        case .failed(let message):
            onFailure(message)
            return false
        }
    }
}
