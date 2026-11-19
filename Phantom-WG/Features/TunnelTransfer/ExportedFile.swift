import Foundation

/// The bytes of one exported file and the name it is offered under. The
/// app holds them in memory until `TunnelExportPicker` writes them into
/// its staging folder for the export picker.
struct ExportedFile: Equatable {
    let data: Data
    let name: String
}
