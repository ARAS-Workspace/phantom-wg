import SwiftUI
import Network

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
