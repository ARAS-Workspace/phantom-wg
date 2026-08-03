import SwiftUI
import Network

/// Physical-interface picker. The user either lets the extension pick
/// the primary path automatically or pins a specific BSD interface
/// (Wi-Fi, Ethernet, …) for bypass relays. Disabling split-tunnelling
/// also disables this row — the selection stays persisted so re-enabling
/// restores intent.
struct SplitTunnelingInterfaceSection: View {
    @Binding var selection: InterfaceSelection
    let availableInterfaces: [NWInterface]
    let isDisabled: Bool
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            Picker(selection: $selection) {
                Text(loc.t("split_tunneling_interface_auto"))
                    .tag(InterfaceSelection.auto)
                    .accessibilityIdentifier(AXID.SplitTunneling.interfaceAuto)

                if availableInterfaces.isEmpty {
                    // Always show the saved explicit entry even if the
                    // resolver hasn't yet populated the list, so the
                    // user's current selection doesn't flicker to Auto.
                    if case .explicit(let name) = selection {
                        Text(name)
                            .tag(InterfaceSelection.explicit(name: name))
                    }
                } else {
                    ForEach(availableInterfaces, id: \.name) { iface in
                        Text(iface.displayLabel)
                            .tag(InterfaceSelection.explicit(name: iface.name))
                    }
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(isDisabled)
            .accessibilityIdentifier(AXID.SplitTunneling.interfacePicker)
        } header: {
            Label(loc.t("split_tunneling_interface_header"), systemImage: "network")
                .padding(.leading, 4)
        } footer: {
            Text(loc.t("split_tunneling_interface_footer"))
                .padding(.leading, 4)
        }
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

// MARK: - Previews

/// `NWInterface` cannot be fabricated, so the picker list itself stays
/// empty in the canvas; the explicit variant shows the saved-entry
/// fallback path (selection preserved with no resolver data).
#Preview("Auto") {
    PreviewBindingHost(InterfaceSelection.auto) { selection in
        Form {
            SplitTunnelingInterfaceSection(selection: selection, availableInterfaces: [], isDisabled: false)
        }
        .formStyle(.grouped)
    }
    .previewEnvironment()
    .frame(width: 560)
}

#Preview("Explicit saved entry") {
    PreviewBindingHost(InterfaceSelection.explicit(name: "en0")) { selection in
        Form {
            SplitTunnelingInterfaceSection(selection: selection, availableInterfaces: [], isDisabled: false)
        }
        .formStyle(.grouped)
    }
    .previewEnvironment()
    .frame(width: 560)
}

#Preview("Disabled") {
    PreviewBindingHost(InterfaceSelection.auto) { selection in
        Form {
            SplitTunnelingInterfaceSection(selection: selection, availableInterfaces: [], isDisabled: true)
        }
        .formStyle(.grouped)
    }
    .previewEnvironment()
    .frame(width: 560)
}
