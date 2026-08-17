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
    /// A STOP whose disarm save was refused. The stop itself went out;
    /// what failed is standing the reconnect rule down, so the rule may
    /// still be in the store and the system may bring this tunnel back
    /// on its own. Distinct from `savingFailed` for the reason the
    /// enum exists: nothing here was being configured, and telling the
    /// user a configuration could not be saved describes neither what
    /// happened nor what may happen next. This is the caption
    /// `clearErrorOnRise` deliberately preserves across a revival,
    /// which only works if the sentence names the revival.
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

    /// The extension answered the reset, and said it had no running
    /// layer to rebuild. Worth surfacing rather than swallowing: the
    /// app only offers Reset on a tunnel it is showing as up, so this
    /// is the two sides disagreeing about what is running.
    case resetNothingToRebuild
    /// The extension answered the reset, and the layer did not come
    /// back. Collapses wstunnel's failure and the adapter's on
    /// purpose — they stay apart on the wire and in the extension's
    /// log, which is where the next step differs, but what the user
    /// is told is the same either way and what they can do about it
    /// is the same too.
    case resetLayerDown
    /// The reset was never handed to the session. The text is the
    /// system's own, since only it knows why the send was refused.
    case resetSendFailed(systemError: String)
    /// Nothing came back from the reset inside its budget. Not a
    /// verdict about the layer: an extension that never answered may
    /// still have rebuilt, so the copy asks for a retry rather than
    /// describing a state it did not observe.
    case resetUnanswered
    /// The extension answered with an outcome byte this build has no
    /// case for — a NEWER extension naming an ending added after this
    /// app shipped. Neither a success nor a failure: the only fact
    /// observed is that the answer could not be read, and that is
    /// what the copy says.
    case resetOutcomeUnrecognised(raw: UInt8)

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

    /// The failure a reset earns, or `nil` when the layer came back.
    ///
    /// Same shape and same reason as `forVaultWrite` above: a helper
    /// forced to name an error for `.rebuilt` could only invent one
    /// its callers have already excluded. Returning an optional keeps
    /// the call site reading as "ask for the failure, throw it if
    /// there is one", while a case added to `TunnelResetReply` later
    /// has to be answered here rather than defaulting into silence.
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
