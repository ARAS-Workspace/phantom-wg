import SwiftUI
import Network

/// Sheet-hosted editor for the split-tunneling configuration. Opens
/// only after the extension gate has cleared. Eager persistence —
/// every mutation hits `SplitTunnelingStore` immediately.
struct SplitTunnelingView: View {
    @Environment(SplitTunnelingStore.self) private var store
    @Environment(SplitTunnelingSessionCoordinator.self) private var sessionCoordinator
    @Environment(SplitTunnelProviderManager.self) private var providerManager
    @Environment(DNSProxyProviderManager.self) private var dnsProviderManager
    @Environment(DNSProxyDaemonClient.self) private var dnsDaemonClient
    @Environment(SplitTunnelDaemonClient.self) private var splitDaemonClient
    @Environment(PhysicalInterfaceResolver.self) private var interfaceResolver
    @Environment(ToastCenter.self) private var toasts
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    @State private var validationError: AppBundleValidator.ValidationError?
    @State private var duplicateError = false
    @State private var showingValidationError = false
    @State private var showingResetConfirm = false
    @State private var logStore: SplitTunnelLogStore?
    @State private var dnsLogStore: DNSProxyLogStore?

    var body: some View {
        activatedContent
            .frame(minWidth: 520, minHeight: 600)
            .navigationTitle(loc.t("split_tunneling_title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.t("split_tunneling_close")) { dismiss() }
                        .accessibilityIdentifier(AXID.SplitTunneling.closeButton)
                }
            }
            .accessibilityIdentifier(AXID.SplitTunneling.sheet)
            .onAppear(perform: onSheetAppear)
            .onDisappear(perform: onSheetDisappear)
            .onChange(of: store.configuration.interfaceSelection) { _, newSelection in
                toasts.info(interfaceChangeToastMessage(newSelection))
            }
            .onChange(of: store.configuration.isEnabled) { _, _ in
                Task { await logStore?.clear() }
            }
            .toastOverlay()
            .modifier(ValidationAlert(
                showingValidationError: $showingValidationError,
                messageProvider: { validationErrorMessage }
            ))
            .modifier(ResetAlert(
                showingResetConfirm: $showingResetConfirm,
                onReset: { store.reset() }
            ))
    }

    // MARK: - Content

    private var activatedContent: some View {
        Form {
            if interfaceUnavailable {
                Section {
                    InterfaceUnavailableBanner(
                        selectionLabel: interfaceSelectionLabel,
                        onSwitchToAuto: { store.setInterfaceSelection(.auto) },
                        onDisable: { store.setEnabled(false) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            // Toggle = mirror of coordinator state; flips delegate
            // through the store to the coordinator's lifecycle.
            SplitTunnelingEnableSection(
                isEnabled: Binding(
                    get: { sessionCoordinator.state.isUserVisiblyActive },
                    set: { store.setEnabled($0) }
                )
            )

            SplitTunnelingInterfaceSection(
                selection: Binding(
                    get: { store.configuration.interfaceSelection },
                    set: { store.setInterfaceSelection($0) }
                ),
                availableInterfaces: interfaceResolver.interfaces,
                isDisabled: !store.configuration.isEnabled
            )

            SplitTunnelingAppListSection(
                apps: store.configuration.apps.filter { !$0.isSyntheticMDNS },
                isDisabled: !store.configuration.isEnabled,
                resolvedInterfaceLabel: resolvedInterfaceLabel,
                onAddApp: handleAddApp,
                onRemoveApp: { store.removeApp(bundleIdentifier: $0) }
            )

            SplitTunnelingMDNSSection(
                isEnabled: Binding(
                    get: { store.isMDNSResponderEnabled },
                    set: { store.setMDNSResponderEnabled($0) }
                )
            )

            if let logStore, let dnsLogStore {
                LogTabsSection(splitLogStore: logStore, dnsLogStore: dnsLogStore)
            }

            Section {
                Button(role: .destructive) {
                    showingResetConfirm = true
                } label: {
                    Label(loc.t("split_tunneling_reset"), systemImage: "arrow.counterclockwise")
                        .foregroundStyle(.red)
                }
                .accessibilityIdentifier(AXID.SplitTunneling.resetButton)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Interface Resolution (UI layer)

    private var resolvedInterface: NWInterface? {
        switch store.configuration.interfaceSelection {
        case .auto:
            return interfaceResolver.interfaces.first(where: { $0.type == .wiredEthernet })
                ?? interfaceResolver.interfaces.first(where: { $0.type == .wifi })
                ?? interfaceResolver.interfaces.first
        case .explicit(let name):
            return interfaceResolver.interfaces.first(where: { $0.name == name })
        }
    }

    private var resolvedInterfaceLabel: String? {
        resolvedInterface?.displayLabel
    }

    /// True when the feature is enabled and the chosen interface
    /// can't be satisfied. Surfaces the banner.
    private var interfaceUnavailable: Bool {
        guard store.configuration.isEnabled else { return false }
        return resolvedInterface == nil
    }

    private var interfaceSelectionLabel: String {
        switch store.configuration.interfaceSelection {
        case .auto:
            return loc.t("split_tunneling_interface_auto")
        case .explicit(let name):
            return name
        }
    }

    private func interfaceChangeToastMessage(_ selection: InterfaceSelection) -> String {
        switch selection {
        case .auto:
            return loc.t("split_tunneling_toast_switched_to_auto")
        case .explicit(let name):
            let label = interfaceResolver.interfaces.first(where: { $0.name == name })?.displayLabel ?? name
            return String(
                format: loc.t("split_tunneling_toast_switched_to_interface"),
                label
            )
        }
    }

    // MARK: - Lifecycle

    private func onSheetAppear() {
        store.reconcile()
        if logStore == nil {
            let newStore = SplitTunnelLogStore(daemonClient: splitDaemonClient)
            logStore = newStore
            newStore.startPolling()
        }
        if dnsLogStore == nil {
            let newStore = DNSProxyLogStore(daemonClient: dnsDaemonClient)
            dnsLogStore = newStore
            newStore.startPolling()
        }
    }

    private func onSheetDisappear() {
        logStore?.stopPolling()
        dnsLogStore?.stopPolling()
    }

    // MARK: - Add App Flow

    private func handleAddApp() {
        let panel = NSOpenPanel()
        panel.title = loc.t("split_tunneling_picker_prompt")
        panel.prompt = loc.t("split_tunneling_add_app")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch AppBundleValidator.validate(url: url) {
        case .success(let entry):
            let added = store.addApp(entry)
            if !added {
                duplicateError = true
                validationError = nil
                showingValidationError = true
            }
        case .failure(let error):
            validationError = error
            duplicateError = false
            showingValidationError = true
        }
    }

    private var validationErrorMessage: String {
        if duplicateError {
            return loc.t("split_tunneling_err_duplicate")
        }
        guard let error = validationError else { return "" }
        switch error {
        case .notABundle:         return loc.t("split_tunneling_err_not_a_bundle")
        case .noBundleIdentifier: return loc.t("split_tunneling_err_no_bundle_id")
        case .notSigned:          return loc.t("split_tunneling_err_not_signed")
        }
    }
}

// MARK: - Alert Modifiers

private struct ValidationAlert: ViewModifier {
    @Binding var showingValidationError: Bool
    let messageProvider: () -> String
    @Environment(LocalizationManager.self) private var loc

    func body(content: Content) -> some View {
        content.alert(loc.t("error"), isPresented: $showingValidationError) {
            Button(loc.t("ok")) {}
                .accessibilityIdentifier(AXID.SplitTunneling.errorAlertOK)
        } message: {
            Text(messageProvider())
        }
    }
}

private struct ResetAlert: ViewModifier {
    @Binding var showingResetConfirm: Bool
    let onReset: () -> Void
    @Environment(LocalizationManager.self) private var loc

    func body(content: Content) -> some View {
        content.alert(loc.t("split_tunneling_reset_confirm_title"),
                      isPresented: $showingResetConfirm) {
            Button(loc.t("cancel"), role: .cancel) {}
                .accessibilityIdentifier(AXID.SplitTunneling.resetCancel)
            Button(loc.t("split_tunneling_reset"), role: .destructive, action: onReset)
                .accessibilityIdentifier(AXID.SplitTunneling.resetConfirm)
        } message: {
            Text(loc.t("split_tunneling_reset_confirm_message"))
        }
    }
}
