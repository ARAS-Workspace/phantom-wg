import Foundation

enum SharedConstants {
    static let appGroupID = "group.com.remrearas.phantom-wg-macos"

    /// Location of the split-tunnelling configuration JSON inside
    /// the App Group container. Written by `SplitTunnelingStore` for
    /// main-app persistence. Extensions receive the configuration
    /// through `providerConfiguration["split_config"]` at startup
    /// and over their `ProxyConfigDaemon` XPC channels
    /// (`applyConfig`) for live updates — neither reads this file.
    static var splitTunnelingConfigurationFileURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }
        return container.appendingPathComponent("split-tunneling.json")
    }

}
