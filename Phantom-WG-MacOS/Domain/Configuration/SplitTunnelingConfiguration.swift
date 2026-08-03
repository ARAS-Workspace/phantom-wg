import Foundation

// MARK: - Split Tunneling Configuration

/// App-wide split tunneling configuration. Exclude semantics: apps
/// in `apps` bypass the tunnel through the physical interface; every
/// other flow stays on the OS default route. Persisted as JSON in
/// the App Group container; delivered to extensions at startup via
/// `providerConfiguration["split_config"]` and live-updated over
/// each proxy's `ProxyConfigDaemon` XPC channel (`applyConfig`).
struct SplitTunnelingConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var interfaceSelection: InterfaceSelection
    var apps: [AppEntry]

    /// Empty, disabled baseline. Used for first-run state and Reset.
    static let `default` = SplitTunnelingConfiguration(
        isEnabled: false,
        interfaceSelection: .auto,
        apps: []
    )

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case interfaceSelection = "interface_selection"
        case apps
    }

    init(isEnabled: Bool, interfaceSelection: InterfaceSelection, apps: [AppEntry]) {
        self.isEnabled = isEnabled
        self.interfaceSelection = interfaceSelection
        self.apps = apps
    }

    /// Forward-compatible decoder — missing `interface_selection`
    /// defaults to `.auto`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        self.apps = try container.decode([AppEntry].self, forKey: .apps)
        self.interfaceSelection = try container.decodeIfPresent(
            InterfaceSelection.self,
            forKey: .interfaceSelection
        ) ?? .auto
    }
}

// MARK: - Interface Selection

/// `auto` lets the extension pick the primary non-tunnel path;
/// `explicit` pins to a specific BSD name. Serialized as `"auto"`
/// or `"explicit:en0"`.
enum InterfaceSelection: Codable, Equatable, Hashable {
    case auto
    case explicit(name: String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "auto" {
            self = .auto
        } else if raw.hasPrefix("explicit:") {
            self = .explicit(name: String(raw.dropFirst("explicit:".count)))
        } else {
            self = .auto
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto:
            try container.encode("auto")
        case .explicit(let name):
            try container.encode("explicit:\(name)")
        }
    }
}

// MARK: - App Entry

/// Identity is the **code signing identifier** as reported by
/// Security framework — `<teamID>.<bundleID>` for Developer ID,
/// `<bundleID>` for Apple-signed apps. Matched at runtime against
/// each flow's `sourceAppSigningIdentifier` via
/// `FlowDecisionEngine.matches`.
struct AppEntry: Codable, Equatable, Identifiable {
    var signingIdentifier: String
    var bundleIdentifier: String
    var displayName: String
    var teamName: String?
    var lastKnownPath: String?

    var id: String { signingIdentifier }

    enum CodingKeys: String, CodingKey {
        case signingIdentifier = "signing_identifier"
        case bundleIdentifier = "bundle_identifier"
        case displayName = "display_name"
        case teamName = "team_name"
        case lastKnownPath = "last_known_path"
        // Legacy — still decoded so older configs migrate.
        case teamIdentifier = "team_identifier"
    }

    init(
        signingIdentifier: String,
        bundleIdentifier: String,
        displayName: String,
        teamName: String? = nil,
        lastKnownPath: String? = nil
    ) {
        self.signingIdentifier = signingIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.teamName = teamName
        self.lastKnownPath = lastKnownPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.teamName = try container.decodeIfPresent(String.self, forKey: .teamName)
        self.lastKnownPath = try container.decodeIfPresent(String.self, forKey: .lastKnownPath)

        if let value = try container.decodeIfPresent(String.self, forKey: .signingIdentifier) {
            self.signingIdentifier = value
        } else if let team = try container.decodeIfPresent(String.self, forKey: .teamIdentifier),
                  !team.isEmpty {
            self.signingIdentifier = "\(team).\(bundleIdentifier)"
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.signingIdentifier,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "AppEntry missing signing identifier"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(signingIdentifier, forKey: .signingIdentifier)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(teamName, forKey: .teamName)
        try container.encodeIfPresent(lastKnownPath, forKey: .lastKnownPath)
    }
}

// MARK: - Synthetic mDNSResponder Pair

/// Adds the system DNS resolver process pair to the matched-app
/// list so apps using `Network.framework` / libresolv (which reach
/// DNSProxy as `com.apple.mDNSResponder`, not as the originating
/// app) get pinned to the physical interface. Membership is
/// user-controlled via the "System DNS Resolver" toggle — list
/// membership IS the toggle state.
extension AppEntry {

    static let mDNSResponder = AppEntry(
        signingIdentifier: "com.apple.mDNSResponder",
        bundleIdentifier: "com.apple.mDNSResponder",
        displayName: "System DNS (mDNSResponder)"
    )

    static let mDNSResponderHelper = AppEntry(
        signingIdentifier: "com.apple.mDNSResponderHelper",
        bundleIdentifier: "com.apple.mDNSResponderHelper",
        displayName: "System DNS (mDNSResponderHelper)"
    )

    /// True for the synthetic mDNSResponder pair. The app list UI
    /// filters these out so users manage them via the toggle.
    var isSyntheticMDNS: Bool {
        signingIdentifier == AppEntry.mDNSResponder.signingIdentifier ||
        signingIdentifier == AppEntry.mDNSResponderHelper.signingIdentifier
    }
}
