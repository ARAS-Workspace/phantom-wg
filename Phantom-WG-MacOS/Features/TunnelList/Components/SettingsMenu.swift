import SwiftUI

struct SettingsMenu: View {
    @Binding var showingUninstallConfirm: Bool
    @Binding var showingSplitTunneling: Bool
    let isUninstalling: Bool
    #if DEBUG
    @Binding var showingTestEngine: Bool
    #endif
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Menu {
            Menu {
                Button {
                    loc.current = .en
                } label: {
                    languageRow(language: .en, isSelected: loc.current == .en)
                }
                .accessibilityIdentifier(AXID.TunnelList.settingsLangEN)

                Button {
                    loc.current = .tr
                } label: {
                    languageRow(language: .tr, isSelected: loc.current == .tr)
                }
                .accessibilityIdentifier(AXID.TunnelList.settingsLangTR)
            } label: {
                Label(loc.t("settings_language"), systemImage: "globe.badge.chevron.backward")
            }
            .accessibilityIdentifier(AXID.TunnelList.settingsLanguage)

            Divider()

            Button {
                showingSplitTunneling = true
            } label: {
                Label(loc.t("settings_split_tunneling"), systemImage: "arrow.triangle.branch")
            }
            .disabled(isUninstalling)
            .accessibilityIdentifier(AXID.TunnelList.settingsSplitTunnel)

            Button(role: .destructive) {
                showingUninstallConfirm = true
            } label: {
                Label(loc.t("settings_uninstall"), systemImage: "trash")
            }
            .disabled(isUninstalling)
            .accessibilityIdentifier(AXID.TunnelList.settingsUninstall)

            #if DEBUG
            Divider()

            Button {
                showingTestEngine = true
            } label: {
                Label(TestEngineStrings.of(loc.current).menuEntry, systemImage: "ladybug")
            }
            .disabled(isUninstalling)
            #endif
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityIdentifier(AXID.TunnelList.settingsMenu)
    }

    @ViewBuilder
    private func languageRow(language: LocalizationManager.Language, isSelected: Bool) -> some View {
        if isSelected {
            Label("\(language.flag) \(language.displayName)", systemImage: "checkmark")
        } else {
            Text("\(language.flag) \(language.displayName)")
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview {
    PreviewBindingHost(false) { uninstall in
        PreviewBindingHost(false) { split in
            PreviewBindingHost(false) { testEngine in
                SettingsMenu(
                    showingUninstallConfirm: uninstall,
                    showingSplitTunneling: split,
                    isUninstalling: false,
                    showingTestEngine: testEngine
                )
            }
        }
    }
    .previewEnvironment()
    .padding(40)
}
#endif
