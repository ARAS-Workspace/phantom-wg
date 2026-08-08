import Foundation

// swiftlint:disable nesting

/// Canonical accessibility identifiers attached to interactive UI
/// elements via `.accessibilityIdentifier(...)`. They give every
/// control a stable, human-independent address for automation and
/// accessibility tooling — think of them as Playwright's
/// `data-testid`. Treat the strings as a public contract: renaming
/// one breaks anything that queries by identifier.
///
/// Convention: `<feature>.<sub-feature>.<element>[.<variant>]`
/// Style:      dot-separated, lower-kebab segments
/// Dynamic:    row-level identifiers take the user-visible tunnel name
enum AXID {

    // MARK: Tunnel List

    enum TunnelList {
        static let addButton         = "tunnel-list.add-button"
        static let emptyImportButton = "tunnel-list.empty.import-button"
        static let languageToggle    = "tunnel-list.language-toggle"

        static let activeToggle = "tunnel-list.active.toggle"
        static let activeError  = "tunnel-list.active.activation-error"
        static let activeNone   = "tunnel-list.active.none"
        static let listCount    = "tunnel-list.count"

        static func row(_ name: String) -> String { "tunnel-row.\(name)" }
        static func rowToggle(_ name: String) -> String { "tunnel-row.\(name).toggle" }
    }

    // MARK: Tunnel Import

    enum TunnelImport {
        static let nameField    = "tunnel-import.name-field"
        static let confEditor   = "tunnel-import.conf-editor"
        static let pasteButton  = "tunnel-import.paste-button"
        static let qrScanButton = "tunnel-import.qr-scan-button"
        static let submitButton = "tunnel-import.submit-button"
        static let errorBanner  = "tunnel-import.error-banner"
    }

    // MARK: Tunnel Detail

    enum TunnelDetail {
        static let statusToggle      = "tunnel-detail.status-toggle"
        static let logsLink          = "tunnel-detail.logs-link"
        static let errorAlertOK      = "tunnel-detail.error-alert.ok"
        static let activationError   = "tunnel-detail.status.activation-error"
        static let modeBadge         = "tunnel-detail.status.mode-badge"
        static let configUnavailable = "tunnel-detail.config-unavailable"

        enum Stats {
            static let handshake = "tunnel-detail.stats.handshake"
            static let rxBytes   = "tunnel-detail.stats.rx-bytes"
            static let txBytes   = "tunnel-detail.stats.tx-bytes"
        }

        enum Name {
            static let field = "tunnel-detail.name.field"
        }

        enum Wstunnel {
            static let url        = "tunnel-detail.wstunnel.url"
            static let secret     = "tunnel-detail.wstunnel.secret"
            static let localHost  = "tunnel-detail.wstunnel.local-host"
            static let localPort  = "tunnel-detail.wstunnel.local-port"
            static let remoteHost = "tunnel-detail.wstunnel.remote-host"
            static let remotePort = "tunnel-detail.wstunnel.remote-port"
        }

        enum Interface {
            static let privateKey = "tunnel-detail.interface.private-key"
            static let addresses  = "tunnel-detail.interface.addresses"
            static let dnsServers = "tunnel-detail.interface.dns-servers"
            static let mtu        = "tunnel-detail.interface.mtu"
        }

        enum Peer {
            static let publicKey    = "tunnel-detail.peer.public-key"
            static let presharedKey = "tunnel-detail.peer.preshared-key"
            static let allowedIPs   = "tunnel-detail.peer.allowed-ips"
            static let endpoint     = "tunnel-detail.peer.endpoint"
            static let keepalive    = "tunnel-detail.peer.keepalive"
        }

        enum Actions {
            static let copyButton    = "tunnel-detail.actions.copy"
            static let editButton    = "tunnel-detail.actions.edit"
            static let resetButton   = "tunnel-detail.actions.reset"
            static let deleteButton  = "tunnel-detail.actions.delete"
            static let deleteConfirm = "tunnel-detail.delete-confirm.confirm"
            static let deleteCancel  = "tunnel-detail.delete-confirm.cancel"
        }
    }

    // MARK: Tunnel Edit

    enum TunnelEdit {
        static let nameField   = "tunnel-edit.name-field"
        static let confEditor  = "tunnel-edit.conf-editor"
        static let saveButton  = "tunnel-edit.save-button"
        static let errorBanner = "tunnel-edit.error-banner"
    }

    // MARK: Log View

    enum LogView {
        static let emptyState  = "log-view.empty-state"
        static let list        = "log-view.list"
        static let copyButton  = "log-view.copy-button"
        static let clearButton = "log-view.clear-button"
    }
}

// swiftlint:enable nesting
