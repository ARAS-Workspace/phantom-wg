import SwiftUI
import Network

/// Sheet-hosted editor for the split-tunneling configuration. Opens
/// only after the extension gate has cleared. Eager persistence —
/// every mutation hits `SplitTunnelingStore` immediately.
struct SplitTunnelingView: View {
    @Environment(SplitTunnelingStore.self) private var store
    @Environment(SplitTunnelingSessionCoordinator.self) private var sessionCoordinator
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
    @State private var logStore: ProxyLogStore?
    @State private var dnsLogStore: ProxyLogStore?

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
            // A push that did not land used to end in os_log and
            // nowhere else, so the row appeared in the list and the
            // screen was indistinguishable from a successful edit.
            // `.notRunning` is deliberately silent here: with the
            // feature stopped, an edit not reaching the extensions is
            // the normal case, not a failure worth interrupting for.
            .onChange(of: store.lastPush) { _, report in
                guard let report, case .pushed = report.outcome, !report.outcome.bothLanded else { return }
                toasts.error(loc.t("split_tunneling_push_failed"))
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

    /// Editors follow the SESSION, not the persisted intent — one
    /// source, the same one the toggle above reads.
    ///
    /// The two used to diverge exactly where it mattered. A start the
    /// user cancelled at the system's permission prompt leaves the
    /// intent ON while the session is `.stopped`: the toggle read the
    /// coordinator and went dark, the selector and the list read the
    /// stored bool and stayed fully lit and editable, and the screen
    /// said two things at once.
    ///
    /// `.starting` and `.stopping` are LOCKED rather than merely
    /// mirrored, and that is the second half of the reason: an edit
    /// made in that window reaches disk and never reaches either
    /// extension, because `reconfigure` pushes only while `.running`.
    /// Nothing told the user, and the next start carries a payload the
    /// running session never saw.
    private var editorsDisabled: Bool { sessionCoordinator.state != .running }

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
            // Locked while a transition is in flight. The toggle reads
            // `.starting` as ON, so the seconds `saveToPreferences`
            // spends inside the system's proxy-permission dialog look
            // exactly like a finished start — and a second tap there
            // does not cancel anything, it dispatches a `stop` that
            // interleaves with the `start` still running, over the same
            // `NEDNSProxyManager.shared()` singleton. The documented
            // ending of that race is SplitTunnel up with DNSProxy down:
            // the port-53 carve-out open with nothing behind it, so a
            // listed app's data leaves the physical interface while its
            // DNS goes to the tunnel's resolver.
            //
            // This closes the reachable trigger, not the race. The
            // coordinator still accepts `start` while `.stopping`; that
            // guard belongs with the in-flight handle the tunnel side
            // already carries.
            SplitTunnelingEnableSection(
                isEnabled: Binding(
                    get: { sessionCoordinator.state.isUserVisiblyActive },
                    set: { store.setEnabled($0) }
                )
            )
            .disabled(sessionCoordinator.state == .starting || sessionCoordinator.state == .stopping)

            SplitTunnelingInterfaceSection(
                selection: Binding(
                    get: { store.configuration.interfaceSelection },
                    set: { store.setInterfaceSelection($0) }
                ),
                availableInterfaces: interfaceResolver.interfaces,
                isDisabled: editorsDisabled
            )

            SplitTunnelingAppListSection(
                apps: store.configuration.apps.filter { !$0.isSyntheticMDNS },
                isDisabled: editorsDisabled,
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
            let newStore = ProxyLogStore(daemonClient: splitDaemonClient, tag: "SPL")
            logStore = newStore
            newStore.startPolling()
        }
        if dnsLogStore == nil {
            let newStore = ProxyLogStore(daemonClient: dnsDaemonClient, tag: "DNS")
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

// MARK: - Previews

/// The preview host has no physical interfaces (`NWInterface` cannot
/// be fabricated), so the enabled variant also demonstrates the
/// interface-unavailable banner — that pairing is inherent to the
/// canvas, not a bug in the view.
#Preview("Enabled") {
    NavigationStack {
        SplitTunnelingView()
    }
    .previewEnvironment(
        splitStore: PreviewFixtures.splitStore(enabled: true),
        sessionState: .running
    )
    .frame(width: 560, height: 700)
}

#Preview("Disabled") {
    NavigationStack {
        SplitTunnelingView()
    }
    .previewEnvironment(
        splitStore: PreviewFixtures.splitStore(enabled: false),
        sessionState: .stopped
    )
    .frame(width: 560, height: 700)
}
