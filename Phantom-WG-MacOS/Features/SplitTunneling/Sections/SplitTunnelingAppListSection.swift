import SwiftUI

/// Scrollable list of picked applications plus the "Add Application…"
/// entry point. The empty state frames the feature as *interface
/// routing* — "apps routed through en0" — rather than "apps that
/// escape the tunnel", because that's the accurate mental model: every
/// app already picks some interface via the kernel's routing decision,
/// and this list is how the user overrides that decision for specific
/// apps.
struct SplitTunnelingAppListSection: View {
    let apps: [AppEntry]
    let isDisabled: Bool
    let resolvedInterfaceLabel: String?
    let onAddApp: () -> Void
    let onRemoveApp: (String) -> Void
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            if apps.isEmpty {
                emptyState
            } else {
                ForEach(apps) { entry in
                    AppEntryRow(entry: entry, onRemove: { onRemoveApp(entry.bundleIdentifier) })
                }
            }

            Button(action: onAddApp) {
                Label(loc.t("split_tunneling_add_app"), systemImage: "plus")
            }
            .accessibilityIdentifier(AXID.SplitTunneling.addAppButton)
        } header: {
            Label(headerTitle, systemImage: "arrow.triangle.branch")
                .padding(.leading, 4)
        } footer: {
            Text(loc.t("split_tunneling_exclude_applications_footer"))
                .padding(.leading, 4)
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }

    // MARK: - Header

    private var headerTitle: String {
        if let label = resolvedInterfaceLabel {
            return String(
                format: loc.t("split_tunneling_routed_header_with_interface"),
                label
            )
        }
        return loc.t("split_tunneling_exclude_applications")
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)

            Text(emptyStateTitle)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(loc.t("split_tunneling_empty_state_description"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 8)
        .accessibilityIdentifier(AXID.SplitTunneling.emptyState)
    }

    private var emptyStateTitle: String {
        if let label = resolvedInterfaceLabel {
            return String(
                format: loc.t("split_tunneling_empty_state_title_with_interface"),
                label
            )
        }
        return loc.t("split_tunneling_empty_state_title")
    }
}

// MARK: - Previews

#Preview("Populated") {
    Form {
        SplitTunnelingAppListSection(
            apps: PreviewFixtures.appEntries,
            isDisabled: false,
            resolvedInterfaceLabel: "Wi-Fi (en0)",
            onAddApp: {},
            onRemoveApp: { _ in }
        )
    }
    .formStyle(.grouped)
    .previewEnvironment()
    .frame(width: 560)
}

#Preview("Empty") {
    Form {
        SplitTunnelingAppListSection(
            apps: [],
            isDisabled: false,
            resolvedInterfaceLabel: "Wi-Fi (en0)",
            onAddApp: {},
            onRemoveApp: { _ in }
        )
    }
    .formStyle(.grouped)
    .previewEnvironment()
    .frame(width: 560)
}

#Preview("Disabled") {
    Form {
        SplitTunnelingAppListSection(
            apps: PreviewFixtures.appEntries,
            isDisabled: true,
            resolvedInterfaceLabel: nil,
            onAddApp: {},
            onRemoveApp: { _ in }
        )
    }
    .formStyle(.grouped)
    .previewEnvironment()
    .frame(width: 560)
}
