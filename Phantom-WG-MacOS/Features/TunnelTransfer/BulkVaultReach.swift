import Foundation

struct BulkVaultReach {
    static let limit = 3

    private(set) var unreachableInARow = 0

    var gaveUp: Bool { unreachableInARow >= Self.limit }

    mutating func landed() {
        unreachableInARow = 0
    }

    mutating func failed(with error: Error) {
        if case .vaultUnavailable? = error as? TunnelManagementError {
            unreachableInARow += 1
        } else {
            unreachableInARow = 0
        }
    }
}
