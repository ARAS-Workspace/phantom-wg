import UIKit

/// The detail's `.conf` export through UIKit's export picker. The file is
/// written into the staging folder (`tmp/Export`) with mode 0600 and handed
/// to the picker, which moves it where the user chooses. Saved or
/// cancelled, the picker answers and the folder is removed. A file a run
/// left while the picker was open is removed at launch
/// (`TunnelsManager.create()`).
///
/// The picker refers to its delegate weakly, so an exporter holds itself
/// from `present` until the picker answers.
@MainActor
final class TunnelExportPicker: NSObject, UIDocumentPickerDelegate {

    nonisolated static let stagingFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Export", isDirectory: true)

    let folder: URL
    private var keepAlive: TunnelExportPicker?

    init(folder: URL = TunnelExportPicker.stagingFolder) {
        self.folder = folder
    }

    /// Writes the file into the folder with mode 0600 and answers its URL.
    ///
    /// @witness TunnelTransfer.theStagedFileLivesUntilThePickerAnswers
    func stage(_ file: ExportedFile) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(file.name)
        try file.data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// Stages the file and presents the export picker over `presenter`.
    func present(_ file: ExportedFile, over presenter: UIViewController) throws {
        let url = try stage(file)
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: false)
        picker.delegate = self
        keepAlive = self
        presenter.present(picker, animated: true)
    }

    /// @witness TunnelTransfer.theStagedFileLivesUntilThePickerAnswers
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish()
    }

    /// @witness TunnelTransfer.theStagedFileLivesUntilThePickerAnswers
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish()
    }

    private func finish() {
        Self.sweep(folder)
        keepAlive = nil
    }

    /// Removes the staging folder and everything in it.
    ///
    /// @witness TunnelTransfer.theStagedFileLivesUntilThePickerAnswers
    /// @witness TunnelTransfer.aLeftoverStagedFileIsSweptAtLaunch
    nonisolated static func sweep(_ folder: URL = TunnelExportPicker.stagingFolder) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The view controller on top of the active window, to present over.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController {
            top = next
        }
        return top
    }
}
