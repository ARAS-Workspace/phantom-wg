import SwiftUI

/// Tüm UI kurallarının merkezi yönetim noktası.
///
/// View'lar kendi enabled/disabled/visibility kararlarını oluşturmak yerine
/// bu engine'e danışır. Tüm fonksiyonlar pure — side-effect yok,
/// TunnelStatus enum'u ve primitive tipler alır, sonuç döner.
/// Bu sayede Swift Testing ile mantıksal olarak uygun ve verimli mocking yapılabilir, UI test edilebilir.
///
/// Central management point for all UI rules.
///
/// Views consult this engine instead of making their own enabled/disabled/visibility
/// decisions. All functions are pure — no side effects; they take TunnelStatus enums
/// and primitive types as input and return results.
/// This makes them testable with Swift Testing through logically sound and efficient mocking, enabling UI testing.

enum PhantomUIEngine {

    // ═══════════════════════════════════════════════════════
    // MARK: - A. Etkileşim Kuralları (Enabled/Disabled)
    //         A. Interaction Rules (Enabled/Disabled)
    // ═══════════════════════════════════════════════════════

    /// A1: Config alanları edit edilebilir mi?
    /// Tunnel aktifken config değiştirilemez — kullanıcı önce bağlantıyı kesmeli.
    ///
    /// A1: Can config fields be edited?
    /// Config cannot be modified while tunnel is active — user must disconnect first.
    static func canEditConfig(status: TunnelStatus) -> Bool {
        status == .inactive
    }

    /// A2: Tunnel silinebilir mi?
    /// Tunnel aktifken silinemez.
    ///
    /// A2: Can the tunnel be deleted?
    /// Cannot be deleted while tunnel is active.
    static func canDeleteTunnel(status: TunnelStatus) -> Bool {
        status == .inactive
    }

    /// A3/A4/A5: Yeni tunnel import edilebilir mi? Swipe-to-delete aktif mi?
    /// Herhangi bir tunnel aktifken (inactive dışında) yeni import ve toplu silme engellenir.
    ///
    /// A3/A4/A5: Can a new tunnel be imported? Is swipe-to-delete enabled?
    /// Import and bulk deletion are blocked when any tunnel is not inactive.
    static func canModifyTunnelList(statuses: [TunnelStatus]) -> Bool {
        !statuses.contains { $0 != .inactive }
    }

    /// A6: Import submit butonu aktif mi?
    /// Boş text ile import yapılamaz.
    ///
    /// A6: Is the import submit button enabled?
    /// Cannot import with empty text.
    static func canSubmitImport(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - B. Görünürlük Kuralları (Visibility)
    //         B. Visibility Rules
    // ═══════════════════════════════════════════════════════

    /// B1: Stats section görünür mü?
    /// Yalnızca tunnel aktifken transfer istatistikleri anlamlıdır.
    ///
    /// B1: Should the stats section be visible?
    /// Transfer statistics are only meaningful while the tunnel is active.
    static func shouldShowStats(status: TunnelStatus) -> Bool {
        status != .inactive
    }

    /// B2: Activation hata metni görünür mü?
    ///
    /// B2: Should the activation error text be visible?
    static func shouldShowActivationError(_ error: TunnelActivationError?) -> Bool {
        error != nil
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - C. Görsel Kuralları (Appearance)
    //         C. Appearance Rules
    // ═══════════════════════════════════════════════════════

    /// C1: Tunnel status → renk eşlemesi.
    /// Tüm view'lar (TunnelRow, TunnelDetailView) aynı renk tablosunu kullanır.
    ///
    /// C1: Tunnel status → color mapping.
    /// All views (TunnelRow, TunnelDetailView) use the same color table.
    static func statusColor(for status: TunnelStatus) -> Color {
        switch status {
        case .active:
            return .green
        case .activating, .waiting, .reasserting, .restarting, .deactivating:
            return .orange
        case .inactive:
            return .secondary
        }
    }

    /// C2: Tunnel status → SF Symbol ikon eşlemesi.
    ///
    /// C2: Tunnel status → SF Symbol icon mapping.
    static func statusIcon(for status: TunnelStatus) -> String {
        switch status {
        case .active:
            return "shield.checkered"
        case .activating, .waiting, .reasserting, .restarting:
            return "arrow.triangle.2.circlepath"
        case .deactivating:
            return "arrow.down.circle"
        case .inactive:
            return "shield.slash"
        }
    }

    /// C3: Config field foreground stili.
    /// Disabled alanlar secondary renkte gösterilir.
    ///
    /// C3: Config field foreground style.
    /// Disabled fields are shown in secondary color.
    static func fieldForegroundStyle(status: TunnelStatus) -> Color {
        canEditConfig(status: status) ? .primary : .secondary
    }

    /// C4: Log tag → renk eşlemesi.
    ///
    /// C4: Log tag → color mapping.
    static func logTagColor(_ tag: String) -> Color {
        switch tag {
        case "WS":  return .orange
        case "WG":  return .green
        case "TUN": return .blue
        default:    return .secondary
        }
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - D. Davranış Kuralları (Behavior)
    //         D. Behavior Rules
    // ═══════════════════════════════════════════════════════

    /// D1: Config değişikliği auto-save edilmeli mi?
    /// Yalnızca tunnel inaktifken ve değişiklik varsa.
    ///
    /// D1: Should config changes be auto-saved?
    /// Only when the tunnel is inactive and there are unsaved changes.
    static func shouldAutoSave(
        status: TunnelStatus,
        hasChanges: Bool
    ) -> Bool {
        hasChanges && canEditConfig(status: status)
    }

    /// D5: Toggle switch ON durumu.
    /// Bu fonksiyon Binding oluşturmaz — sadece mantıksal sonucu döner.
    /// View'lar bu sonucu Binding<Bool>.get içinde kullanır.
    ///
    /// D5: Toggle switch ON state.
    /// This function does not create a Binding — it only returns the logical result.
    /// Views use this result inside Binding<Bool>.get.
    static func isToggleOn(status: TunnelStatus) -> Bool {
        switch status {
        case .active, .activating, .waiting, .reasserting, .restarting:
            return true
        case .inactive, .deactivating:
            return false
        }
    }

    /// Toggle switch Binding factory.
    /// TunnelRow ve TunnelDetailView'da birebir aynı olan binding'i tek noktadan üretir.
    ///
    /// Toggle switch Binding factory.
    /// Produces the identical binding used in both TunnelRow and TunnelDetailView from a single source.
    @MainActor
    static func tunnelToggleBinding(
        for tunnel: TunnelContainer,
        manager: TunnelsManager
    ) -> Binding<Bool> {
        Binding(
            get: { isToggleOn(status: tunnel.status) },
            set: { isOn in
                if isOn {
                    manager.startActivation(of: tunnel)
                } else {
                    manager.startDeactivation(of: tunnel)
                }
            }
        )
    }
}
