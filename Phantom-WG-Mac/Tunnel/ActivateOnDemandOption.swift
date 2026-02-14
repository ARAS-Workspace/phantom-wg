import NetworkExtension

enum ActivateOnDemandOption: Equatable {
    case off
    case wifiOnly
    case anyNetwork

    static func from(provider: TunnelProviding) -> ActivateOnDemandOption {
        guard provider.isOnDemandEnabled, let rules = provider.onDemandRules, !rules.isEmpty else {
            return .off
        }

        for rule in rules {
            guard rule is NEOnDemandRuleConnect else { continue }
            if rule.interfaceTypeMatch == .wiFi { return .wifiOnly }
            if rule.interfaceTypeMatch == .any { return .anyNetwork }
        }

        return .anyNetwork
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
        case .anyNetwork:
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .any
            provider.onDemandRules = [rule]
            provider.isOnDemandEnabled = true
        }
    }
}
