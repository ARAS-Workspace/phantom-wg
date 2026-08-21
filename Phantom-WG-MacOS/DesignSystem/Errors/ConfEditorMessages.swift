import Foundation

enum ConfEditorMessages {

    private static let fieldOrder: [TunnelDraft.Field] = [
        .name,
        .wstunnelUrl, .wstunnelSecret,
        .wstunnelLocalHost, .wstunnelLocalPort,
        .wstunnelRemoteHost, .wstunnelRemotePort,
        .interfacePrivateKey, .interfaceAddresses,
        .interfaceDnsServers, .interfaceMTU,
        .peerPublicKey, .peerPresharedKey,
        .peerAllowedIPs, .peerEndpoint, .peerPersistentKeepalive
    ]

    // MARK: - Parse Errors

    static func parseMessage(_ error: ConfParser.ParseError, loc: LocalizationManager) -> String {
        switch error {
        case .emptyInput:
            return loc.t("parse_err_empty_input")
        case .noInterfaceSection:
            return loc.t("parse_err_no_interface")
        case .noPeerSection:
            return loc.t("parse_err_no_peer")
        case .duplicateSection(let section):
            return loc.t("parse_err_duplicate_section", section)
        case .missingKey(let section, let key):
            return loc.t("parse_err_missing_key", section, key)
        case .invalidTunnelFormat(let section, let key):
            return loc.t("parse_err_invalid_tunnel", section, key)
        }
    }

    // MARK: - Field Errors

    static func fieldMessages(
        _ errors: [TunnelDraft.Field: FieldValidationError],
        loc: LocalizationManager
    ) -> [String] {
        fieldOrder.compactMap { field in
            guard let error = errors[field] else { return nil }
            return "\(fieldLabel(field, loc: loc)): \(error.localizedMessage(loc))"
        }
    }

    private static func fieldLabel(_ field: TunnelDraft.Field, loc: LocalizationManager) -> String {
        switch field {
        case .name:                     return loc.t("detail_name")
        case .interfacePrivateKey:      return loc.t("detail_private_key")
        case .interfaceAddresses:       return loc.t("detail_address")
        case .interfaceDnsServers:      return loc.t("detail_dns")
        case .interfaceMTU:             return loc.t("detail_mtu")
        case .peerPublicKey:            return loc.t("detail_public_key")
        case .peerPresharedKey:         return loc.t("detail_preshared_key")
        case .peerAllowedIPs:           return loc.t("detail_allowed_ips")
        case .peerEndpoint:             return loc.t("detail_endpoint")
        case .peerPersistentKeepalive:  return loc.t("detail_keepalive")
        case .wstunnelUrl:              return loc.t("detail_server_url")
        case .wstunnelSecret:           return loc.t("detail_secret")
        case .wstunnelLocalHost:        return loc.t("detail_local_host")
        case .wstunnelLocalPort:        return loc.t("detail_local_port")
        case .wstunnelRemoteHost:       return loc.t("detail_remote_host")
        case .wstunnelRemotePort:       return loc.t("detail_remote_port")
        }
    }
}
