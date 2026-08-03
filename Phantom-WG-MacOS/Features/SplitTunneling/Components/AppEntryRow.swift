import SwiftUI
import AppKit

/// One row in the split-tunneling app list. Shows the icon (loaded
/// lazily from `lastKnownPath` with a generic fallback), display name,
/// bundle identifier and signing team — plus an inline remove button
/// on trailing. Identity in the tunnel-side matching pipeline is
/// `<teamID>.<bundleID>`, so both values are surfaced to the operator.
struct AppEntryRow: View {
    let entry: AppEntry
    let onRemove: () -> Void
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(path: entry.lastKnownPath)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Text(entry.bundleIdentifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let teamName = entry.teamName {
                        Text(teamName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text(entry.signingIdentifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(loc.t("split_tunneling_remove_app"))
            .accessibilityIdentifier(AXID.SplitTunneling.appRemove(entry.bundleIdentifier))
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier(AXID.SplitTunneling.appRow(entry.bundleIdentifier))
    }
}

// MARK: - Icon View

/// Small helper that renders the `.app`'s icon via LaunchServices.
/// Falls back to a generic app glyph when the path is missing or the
/// bundle no longer resolves (reconcile should normally prevent this,
/// but the view stays forgiving).
private struct AppIconView: View {
    let path: String?

    var body: some View {
        if let path, let image = Self.loadIcon(at: path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }

    private static func loadIcon(at path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Previews

#Preview {
    List {
        ForEach(PreviewFixtures.appEntries) { entry in
            AppEntryRow(entry: entry, onRemove: {})
        }
        AppEntryRow(
            entry: AppEntry(
                signingIdentifier: "com.example.ghost-app",
                bundleIdentifier: "com.example.ghost-app",
                displayName: "Uninstalled App",
                lastKnownPath: "/Applications/Missing.app"
            ),
            onRemove: {}
        )
    }
    .previewEnvironment()
    .frame(width: 560)
}
