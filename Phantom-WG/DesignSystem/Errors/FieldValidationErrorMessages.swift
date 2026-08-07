import Foundation

// MARK: - Localized Message for FieldValidationError

/// Maps typed validation errors to localized, user-facing messages.
/// Kept separate from the model layer so that error cases stay pure
/// data while the mapping lives next to the UI that consumes it.
extension FieldValidationError {

    func localizedMessage(_ loc: LocalizationManager) -> String {
        switch self {
        case .empty:
            return loc.t("field_err_empty")

        case .wireGuardKey(let err):
            return wireGuardKeyErrorMessage(err, loc: loc)

        case .address(let err, let index):
            let base = addressErrorMessage(err, loc: loc)
            return loc.t("field_err_list_entry", index + 1, base)

        case .ipAddress(let err, let index):
            let base = ipAddressErrorMessage(err, loc: loc)
            return loc.t("field_err_list_entry", index + 1, base)

        case .endpoint(let err):
            return endpointErrorMessage(err, loc: loc)

        case .wstunnelURL(let err):
            return wstunnelURLErrorMessage(err, loc: loc)

        case .intNotParsed(let raw):
            return loc.t("field_err_int_not_parsed", raw)

        case .intOutOfRange(let value, let min, let max):
            return loc.t("field_err_int_out_of_range", value, min, max)
        }
    }

    // MARK: - Per-Type Mappers

    private func wireGuardKeyErrorMessage(
        _ err: WireGuardKey.ParseError,
        loc: LocalizationManager
    ) -> String {
        switch err {
        case .notBase64:
            return loc.t("field_err_key_not_base64")
        case .wrongByteCount(let bytes):
            return loc.t("field_err_key_wrong_length", bytes)
        }
    }

    private func ipAddressErrorMessage(
        _ err: IPAddressEntry.ParseError,
        loc: LocalizationManager
    ) -> String {
        switch err {
        case .invalid(let raw):
            return loc.t("field_err_ip_invalid", raw)
        }
    }

    private func addressErrorMessage(
        _ err: AddressWithPrefix.ParseError,
        loc: LocalizationManager
    ) -> String {
        switch err {
        case .missingSlash:
            return loc.t("field_err_address_missing_slash")
        case .invalidPrefix(let raw):
            return loc.t("field_err_address_invalid_prefix", raw)
        case .invalidAddress(let raw):
            return loc.t("field_err_address_invalid_addr", raw)
        case .prefixOutOfRange(let family, let prefix, let max):
            return loc.t("field_err_address_prefix_range", family, prefix, max)
        }
    }

    private func endpointErrorMessage(
        _ err: IPEndpoint.ParseError,
        loc: LocalizationManager
    ) -> String {
        switch err {
        case .missingPort:
            return loc.t("field_err_endpoint_missing_port")
        case .invalidPort(let raw):
            return loc.t("field_err_endpoint_invalid_port", raw)
        case .portOutOfRange(let value):
            return loc.t("field_err_endpoint_port_range", value)
        case .invalidHost(let raw):
            return loc.t("field_err_endpoint_invalid_host", raw)
        }
    }

    private func wstunnelURLErrorMessage(
        _ err: WstunnelURL.ParseError,
        loc: LocalizationManager
    ) -> String {
        switch err {
        case .notAURL:
            return loc.t("field_err_url_not_a_url")
        case .invalidScheme(let scheme):
            return loc.t("field_err_url_invalid_scheme", scheme ?? "")
        case .missingHost:
            return loc.t("field_err_url_missing_host")
        }
    }
}
