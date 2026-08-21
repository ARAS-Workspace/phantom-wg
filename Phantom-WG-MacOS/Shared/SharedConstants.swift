import Foundation

enum SharedConstants {
    static let appGroupID = "group.com.remrearas.phantom-wg-macos"

    static var splitTunnelingConfigurationFileURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }
        return container.appendingPathComponent("split-tunneling.json")
    }

}
