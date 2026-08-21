import Foundation
import NetworkExtension

enum SlotVerdict: Equatable {
    case free
    case heldByForeign(name: String?)
}

enum SlotClassifier {

    private static func isOccupying(_ status: NEVPNStatus) -> Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    static func classify(
        providers: [TunnelProviding],
        ownedIDs: Set<UUID>,
        probe: (UUID) async -> TunnelVaultClient.Read
    ) async -> SlotVerdict {
        for provider in providers {
            guard isOccupying(provider.connectionStatus) else { continue }
            guard let identity = provider.tunnelIdentity else {
                continue
            }
            if ownedIDs.contains(identity.id) {
                continue
            }
            switch await probe(identity.id) {
            case .missing:
                let name = provider.localizedDescription
                return .heldByForeign(name: name?.isEmpty == false ? name : nil)
            case .config, .undecodable:
                continue
            case .unreachable:
                continue
            }
        }
        return .free
    }
}
