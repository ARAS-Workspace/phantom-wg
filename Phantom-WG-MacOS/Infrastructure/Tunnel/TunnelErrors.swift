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
    /// The attempt outlived its budget without ever resolving: no
    /// session, no failure, nothing left running to move it. Like
    /// `foreignSlotHolder` it carries no system error, and for a
    /// stronger reason — the system never said anything at all, which
    /// is the whole content of this case. Distinct from
    /// `retryLimitReached`, which means the ladder ran its full course
    /// and every rung answered; this one means the attempt stopped
    /// answering.
    case activationUnresolved

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
    /// The vault could not be reached, or did not answer in time. The
    /// write may even have landed with only its reply lost, so the
    /// message points at the extension and a retry is reasonable.
    case vaultUnavailable
    /// Something ANSWERED no, as opposed to nothing answering at all.
    ///
    /// Two things can say it and the difference does not reach here:
    /// the daemon replying that the keychain would not do the write,
    /// and this process failing to encode the payload before the daemon
    /// is asked at all. Both are definitive in the sense that matters
    /// to the user — a state that stands exactly as it was — which is
    /// why they share a case; neither is silence, and silence is the
    /// distinction this case exists to draw.
    ///
    /// What it does NOT promise is that the answer was given three
    /// times. The ladders return the LAST attempt's outcome, so all a
    /// refusal here establishes is that the final try was refused;
    /// earlier ones may have been silence. That is also why the message
    /// stops short of telling the user a retry is pointless: a keychain
    /// can refuse for a moment and relent.
    case vaultRefused
    case vpnSystemErrorOnAddTunnel(systemError: Error)
    case vpnSystemErrorOnModifyTunnel(systemError: Error)
    case vpnSystemErrorOnRemoveTunnel(systemError: Error)

    /// The failure a vault write earns, or `nil` when it finished.
    ///
    /// Total over the enum on purpose: a helper that had to name a
    /// verdict for `.done` would be describing a case its callers have
    /// already excluded, and the only honest thing to put there is an
    /// error nobody can reach. Returning an optional lets every call
    /// site read the same way — ask for the failure, throw it if there
    /// is one — with the compiler still forcing a new `Write` case to be
    /// answered here rather than collapsed at five sites.
    static func forVaultWrite(_ outcome: TunnelVaultClient.Write) -> TunnelManagementError? {
        switch outcome {
        case .done: return nil
        case .refused: return .vaultRefused
        case .unreachable: return .vaultUnavailable
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
        }
    }
}
