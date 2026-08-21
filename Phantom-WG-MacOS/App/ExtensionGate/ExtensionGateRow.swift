import SwiftUI

struct ExtensionGateRow: View {
    let controller: ExtensionGateController
    let onActivate: () -> Void
    let onOpenSettings: () -> Void
    let onRetry: () -> Void

    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 24, height: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(controller.displayName)
                    .font(.body)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = controller.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            actionButton
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch controller.status {
        case .activated:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        case .needsApproval:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        case .notInstalled:
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .font(.title2)
                .foregroundStyle(.red)
        case .activating, .unknown:
            Image(systemName: "circle.dashed")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status Text

    private var statusText: String {
        switch controller.status {
        case .unknown:        return loc.t("gate_status_unknown")
        case .notInstalled:   return loc.t("gate_status_not_installed")
        case .activating:     return loc.t("gate_status_activating")
        case .needsApproval:  return loc.t("gate_status_needs_approval")
        case .activated:      return loc.t("gate_status_activated")
        case .failed:         return loc.t("gate_status_failed")
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        switch controller.status {
        case .activated:
            EmptyView()
        case .notInstalled:
            Button(loc.t("gate_activate"), action: onActivate)
                .buttonStyle(.borderedProminent)
                .prominentLabelLegibleWhenInactive()
                .controlSize(.small)
                .accessibilityIdentifier(AXID.ExtensionGate.rowActivate(controller.bundleID))
        case .needsApproval:
            Button(loc.t("gate_open_settings"), action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .prominentLabelLegibleWhenInactive()
                .controlSize(.small)
                .accessibilityIdentifier(AXID.ExtensionGate.rowOpenSettings(controller.bundleID))
        case .failed:
            Button(loc.t("gate_retry"), action: onRetry)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier(AXID.ExtensionGate.rowRetry(controller.bundleID))
        case .activating, .unknown:
            EmptyView()
        }
    }
}

// MARK: - Previews

private struct ExtensionGateRowGallery: View {
    private let statuses: [ExtensionGateController.Status] = [
        .unknown,
        .notInstalled,
        .activating,
        .needsApproval,
        .activated,
        .failed("The extension was blocked by system policy.")
    ]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                ExtensionGateRow(
                    controller: PreviewFixtures.gateController(titleKey: "gate_ext_tunnel", status: status),
                    onActivate: {},
                    onOpenSettings: {},
                    onRetry: {}
                )
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

#Preview("All statuses — Light") {
    ExtensionGateRowGallery()
        .previewEnvironment(scheme: .light)
}

#Preview("All statuses — Dark") {
    ExtensionGateRowGallery()
        .previewEnvironment(scheme: .dark)
}
