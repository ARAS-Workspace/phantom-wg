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

    // MARK: Extension Gate

    enum ExtensionGate {
        static let checkAgain      = "extension-gate.check-again"
        static let tunnelLoadError = "extension-gate.tunnel-load.error"

        static func rowActivate(_ bundleID: String) -> String {
            "extension-gate.row.\(bundleID).activate"
        }
        static func rowOpenSettings(_ bundleID: String) -> String {
            "extension-gate.row.\(bundleID).open-settings"
        }
        static func rowRetry(_ bundleID: String) -> String {
            "extension-gate.row.\(bundleID).retry"
        }
    }

    // MARK: Connection Gate

    enum ConnectionGate {
        static let checking     = "connection-gate.checking"
        static let heldMessage  = "connection-gate.held-message"
        static let openSettings = "connection-gate.open-settings"
        static let checkAgain   = "connection-gate.check-again"
    }

    // MARK: Vault Gate

    enum VaultGate {
        static let connecting  = "vault-gate.connecting"
        static let silentError = "vault-gate.silent-error"
        static let doorError   = "vault-gate.door-error"
        static let checkAgain  = "vault-gate.check-again"
    }

    // MARK: Tunnel List

    enum TunnelList {
        static let addButton            = "tunnel-list.add-button"
        static let emptyImportButton    = "tunnel-list.empty.import-button"
        static let settingsMenu         = "tunnel-list.settings.menu"
        static let settingsLanguage     = "tunnel-list.settings.language"
        static let settingsLangEN       = "tunnel-list.settings.language.en"
        static let settingsLangTR       = "tunnel-list.settings.language.tr"
        static let settingsSplitTunnel  = "tunnel-list.settings.split-tunneling"
        static let settingsUninstall    = "tunnel-list.settings.uninstall"
        static let uninstallConfirm     = "tunnel-list.uninstall-confirm.confirm"
        static let uninstallCancel      = "tunnel-list.uninstall-confirm.cancel"
        static let errorAlertOK         = "tunnel-list.error-alert.ok"

        static let listCount    = "tunnel-list.count"

        static func row(_ name: String) -> String { "tunnel-row.\(name)" }
        static func rowToggle(_ name: String) -> String { "tunnel-row.\(name).toggle" }
    }

    // MARK: Split Tunneling

    enum SplitTunneling {
        static let sheet             = "split-tunneling.sheet"
        static let closeButton       = "split-tunneling.close-button"
        static let enableToggle      = "split-tunneling.enable-toggle"
        static let interfacePicker   = "split-tunneling.interface.picker"
        static let interfaceAuto     = "split-tunneling.interface.auto"
        static let addAppButton      = "split-tunneling.add-app-button"
        static let emptyState        = "split-tunneling.empty-state"
        static let resetButton       = "split-tunneling.reset-button"
        static let resetConfirm      = "split-tunneling.reset-confirm.confirm"
        static let resetCancel       = "split-tunneling.reset-confirm.cancel"
        static let errorAlertOK      = "split-tunneling.error-alert.ok"

        static let logsCount         = "split-tunneling.logs-count"
        static let logsSave          = "split-tunneling.logs-save"
        static let logsClear         = "split-tunneling.logs-clear"
        static let logsTab           = "split-tunneling.logs.tab"
        static let logsTabSplit      = "split-tunneling.logs.tab.split"
        static let logsTabDns        = "split-tunneling.logs.tab.dns"
        static let mdnsToggle        = "split-tunneling.mdns-toggle"
        static let interfaceUnavailableBanner = "split-tunneling.interface-unavailable-banner"

        static func appRow(_ bundleID: String) -> String { "split-tunneling.app-row.\(bundleID)" }
        static func appRemove(_ bundleID: String) -> String { "split-tunneling.app-remove.\(bundleID)" }
    }

    // MARK: Tunnel Import

    enum TunnelImport {
        static let nameField    = "tunnel-import.name-field"
        static let confEditor   = "tunnel-import.conf-editor"
        static let pasteButton  = "tunnel-import.paste-button"
        static let submitButton = "tunnel-import.submit-button"
        static let errorBanner  = "tunnel-import.error-banner"
    }

    // MARK: Tunnel Detail

    enum TunnelDetail {
        static let statusToggle    = "tunnel-detail.status-toggle"
        static let logsLink        = "tunnel-detail.logs-link"
        static let errorAlertOK    = "tunnel-detail.error-alert.ok"
        static let activationError = "tunnel-detail.status.activation-error"
        static let modeBadge       = "tunnel-detail.status.mode-badge"
        static let configUnavailable = "tunnel-detail.config-unavailable"
        static let configUnreachable = "tunnel-detail.config-unreachable"
        static let configRetry       = "tunnel-detail.config-retry"

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
        static let saveButton  = "log-view.save-button"
        static let clearButton = "log-view.clear-button"
        static let emptyState  = "log-view.empty-state"
        static let list        = "log-view.list"
        static let saveErrorOK = "log-view.save-error.ok"
    }

}

// swiftlint:enable nesting
