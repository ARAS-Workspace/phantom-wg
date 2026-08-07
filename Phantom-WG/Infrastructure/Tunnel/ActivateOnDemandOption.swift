import NetworkExtension

/// UI-facing projection of a manager's on-demand rule set.
///
/// `from(provider:)` tolerates rule sets this app never writes —
/// `.wifiOnly` / `.cellularOnly` exist so an externally authored
/// configuration still reads back faithfully; the app itself only
/// installs `.off` or `.wifiOrCellular` (one
/// `NEOnDemandRuleConnect(.any)`).
///
/// `apply(on:)` deliberately touches only the on-demand fields, not
/// `isEnabled` — enabling the configuration is the activation path's
/// job. On a tunnel that was never activated, an armed rule stays
/// dormant until the system enables the configuration: the switch
/// reflects stored intent, not a live guarantee.
enum ActivateOnDemandOption: Equatable {
    case off
    case wifiOnly
    case cellularOnly
    case wifiOrCellular

    static func from(provider: TunnelProviding) -> ActivateOnDemandOption {
        guard provider.isOnDemandEnabled, let rules = provider.onDemandRules, !rules.isEmpty else {
            return .off
        }

        var hasWiFi = false
        var hasCellular = false

        for rule in rules {
            guard rule is NEOnDemandRuleConnect else { continue }
            if rule.interfaceTypeMatch == .wiFi { hasWiFi = true }
            if rule.interfaceTypeMatch == .cellular { hasCellular = true }
            if rule.interfaceTypeMatch == .any { return .wifiOrCellular }
        }

        if hasWiFi && hasCellular { return .wifiOrCellular }
        if hasWiFi { return .wifiOnly }
        if hasCellular { return .cellularOnly }
        return .wifiOrCellular
    }

    func apply(on provider: TunnelProviding) {
        switch self {
        case .off:
            provider.isOnDemandEnabled = false
        case .wifiOnly:
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .wiFi
            provider.onDemandRules = [rule]
            provider.isOnDemandEnabled = true
        case .cellularOnly:
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .cellular
            provider.onDemandRules = [rule]
            provider.isOnDemandEnabled = true
        case .wifiOrCellular:
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .any
            provider.onDemandRules = [rule]
            provider.isOnDemandEnabled = true
        }
    }
}
