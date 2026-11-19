import Foundation

/// The one door every private-data action goes through: copy, export,
/// edit, and delete ask here first. One question is open at a time; a
/// second request while one is on screen answers `false` without asking.
/// A failure is handed to `onFailure` for the caller to show; a decline
/// stays silent.
@MainActor
enum PrivateDataGuard {

    private static var asking = false

    /// @witness PrivateData.aGrantedOwnerCheckOpensTheDoor
    /// @witness PrivateData.aDeclinedOwnerCheckClosesItSilently
    /// @witness PrivateData.aFailedOwnerCheckClosesItAndNamesTheFailure
    /// @witness PrivateData.aSecondRequestWhileOneIsOpenAnswersFalseWithoutAsking
    static func grants(
        reason: String,
        authorize: (String) async -> PrivateDataAuthorization.Outcome = PrivateDataAuthorization.request,
        onFailure: (String) -> Void
    ) async -> Bool {
        guard !asking else { return false }
        asking = true
        defer { asking = false }

        switch await authorize(reason) {
        case .granted:
            return true
        case .declined:
            return false
        case .failed(let message):
            onFailure(message)
            return false
        }
    }
}
