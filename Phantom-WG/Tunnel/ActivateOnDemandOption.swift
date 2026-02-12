import NetworkExtension

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

    var localizedDescription: String {
        switch self {
        case .off: return "Off"
        case .wifiOnly: return "Wi-Fi Only"
        case .cellularOnly: return "Cellular Only"
        case .wifiOrCellular: return "Wi-Fi or Cellular"
        }
    }
}
