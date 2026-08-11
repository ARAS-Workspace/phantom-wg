import Foundation

enum TunnelActivationError: Error {
    case startingFailed(systemError: Error)
    case savingFailed(systemError: Error)
    case loadingFailed(systemError: Error)
    case retryLimitReached(lastSystemError: Error)
    case failedWhileActivating(systemError: Error)
    /// Another local user's session holds the system's one VPN slot.
    /// No system error rides along: the message IS the diagnosis, and
    /// the fix lives in System Settings > VPN, not in a retry.
    case foreignSlotHolder

    var alertText: String {
        let loc = LocalizationManager.shared
        switch self {
        case .foreignSlotHolder:
            return loc.t("error_foreign_slot")
        case .startingFailed(let error):
            return loc.t("error_starting_failed", error.localizedDescription)
        case .savingFailed(let error):
            return loc.t("error_saving_failed", error.localizedDescription)
        case .loadingFailed(let error):
            return loc.t("error_loading_failed", error.localizedDescription)
        case .retryLimitReached(let error):
            return loc.t("error_retry_limit", error.localizedDescription)
        case .failedWhileActivating(let error):
            return loc.t("error_activation_failed", error.localizedDescription)
        }
    }
}

enum TunnelManagementError: Error, LocalizedError {
    case tunnelAlreadyExistsWithThatName
    case tunnelInvalidName
    case vaultUnavailable
    case vpnSystemErrorOnAddTunnel(systemError: Error)
    case vpnSystemErrorOnModifyTunnel(systemError: Error)
    case vpnSystemErrorOnRemoveTunnel(systemError: Error)

    var errorDescription: String? {
        let loc = LocalizationManager.shared
        switch self {
        case .tunnelAlreadyExistsWithThatName:
            return loc.t("error_duplicate_name")
        case .tunnelInvalidName:
            return loc.t("error_invalid_name")
        case .vaultUnavailable:
            return loc.t("error_vault_unavailable")
        case .vpnSystemErrorOnAddTunnel(let error):
            return loc.t("error_add_tunnel", error.localizedDescription)
        case .vpnSystemErrorOnModifyTunnel(let error):
            return loc.t("error_modify_tunnel", error.localizedDescription)
        case .vpnSystemErrorOnRemoveTunnel(let error):
            return loc.t("error_remove_tunnel", error.localizedDescription)
        }
    }
}
