import Foundation

/// The `.conf` file of one tunnel: its name and its bytes. Mac 2.2.1's
/// `TunnelConfFile` is the source; there it also named the type its save
/// and open panels allow and wrote the file the save panel chose. On iOS
/// `document(of:)` hands the bytes once the owner grants it, and
/// `TunnelExportPicker` stages them for the export picker. The app
/// declares no type for `.conf`: the picker takes the file by its path,
/// and an import decides from the content.
enum TunnelConfFile {

    /// @witness TunnelTransfer.theDetailExportHandsTheConfBytes
    static func fileName(for tunnelName: String) -> String {
        let base = tunnelName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(base).conf"
    }

    /// @witness TunnelTransfer.theDetailExportHandsTheConfBytes
    static func data(_ contents: String) -> Data {
        Data((contents + "\n").utf8)
    }

    /// The document the detail's export hands the export picker: the
    /// tunnel's `.conf`, private key included, once the owner grants it.
    /// Nil when the tunnel reads no configuration, in which case the owner
    /// is not asked, or when the owner does not grant it.
    ///
    /// @witness TunnelTransfer.theDetailExportHandsTheConfBytes
    /// @witness TunnelTransfer.theDetailExportAsksTheOwnerFirst
    @MainActor
    static func document(
        of tunnel: TunnelContainer,
        reason: String,
        authorize: (String) async -> PrivateDataAuthorization.Outcome = PrivateDataAuthorization.request,
        onFailure: (String) -> Void
    ) async -> ExportedFile? {
        guard let config = tunnel.tunnelConfig else { return nil }
        let contents = config.asConfString()
        guard await PrivateDataGuard.grants(reason: reason, authorize: authorize, onFailure: onFailure) else {
            return nil
        }
        return ExportedFile(data: data(contents), name: fileName(for: config.name))
    }
}
