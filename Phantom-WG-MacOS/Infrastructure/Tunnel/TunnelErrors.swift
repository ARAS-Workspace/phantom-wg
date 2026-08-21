import Foundation

enum TunnelActivationError: Error {
    case startingFailed(systemError: Error)
    case savingFailed(systemError: Error)
    case loadingFailed(systemError: Error)
    case retryLimitReached(lastSystemError: Error)
    case failedWhileActivating(systemError: Error)
    case foreignSlotHolder
    case activationUnresolved
    case stopDisarmRefused(systemError: Error)

    var alertText: String {
        let loc = LocalizationManager.shared
        switch self {
        case .foreignSlotHolder:
            return loc.t("error_foreign_slot")
        case .activationUnresolved:
            return loc.t("error_activation_unresolved")
        case .startingFailed(let error):
            return loc.t("error_starting_failed", error.localizedDescription)
        case .savingFailed(let error):
            return loc.t("error_saving_failed", error.localizedDescription)
        case .stopDisarmRefused(let error):
            return loc.t("error_stop_disarm_refused", error.localizedDescription)
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
    case vaultRefused
    case vpnSystemErrorOnAddTunnel(systemError: Error)
    case vpnSystemErrorOnModifyTunnel(systemError: Error)
    case vpnSystemErrorOnRemoveTunnel(systemError: Error)

    case resetNothingToRebuild
    case resetLayerDown
    case resetSendFailed(systemError: String)
    case resetUnanswered
    case resetOutcomeUnrecognised(raw: UInt8)

    static func forVaultWrite(_ outcome: TunnelVaultClient.Write) -> TunnelManagementError? {
        switch outcome {
        case .done: return nil
        case .refused: return .vaultRefused
        case .unreachable: return .vaultUnavailable
        }
    }

    static func forReset(_ reply: TunnelResetReply) -> TunnelManagementError? {
        switch reply {
        case .rebuilt: return nil
        case .skipped: return .resetNothingToRebuild
        case .wstunnelFailed, .adapterFailed: return .resetLayerDown
        }
    }

    var errorDescription: String? {
        let loc = LocalizationManager.shared
        switch self {
        case .tunnelAlreadyExistsWithThatName:
            return loc.t("error_duplicate_name")
        case .tunnelInvalidName:
            return loc.t("error_invalid_name")
        case .vaultUnavailable:
            return loc.t("error_vault_unavailable")
        case .vaultRefused:
            return loc.t("error_vault_refused")
        case .vpnSystemErrorOnAddTunnel(let error):
            return loc.t("error_add_tunnel", error.localizedDescription)
        case .vpnSystemErrorOnModifyTunnel(let error):
            return loc.t("error_modify_tunnel", error.localizedDescription)
        case .vpnSystemErrorOnRemoveTunnel(let error):
            return loc.t("error_remove_tunnel", error.localizedDescription)
        case .resetNothingToRebuild:
            return loc.t("error_reset_nothing_to_rebuild")
        case .resetLayerDown:
            return loc.t("error_reset_layer_down")
        case .resetSendFailed(let description):
            return loc.t("error_reset_send_failed", description)
        case .resetUnanswered:
            return loc.t("error_reset_unanswered")
        case .resetOutcomeUnrecognised(let raw):
            return loc.t("error_reset_outcome_unrecognised", Int(raw))
        }
    }
}
