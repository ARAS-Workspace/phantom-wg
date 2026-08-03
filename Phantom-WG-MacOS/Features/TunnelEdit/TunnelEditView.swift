import SwiftUI

/// Raw-text editor for an existing tunnel — the WireGuard app
/// pattern: tunnel name on top, the full `.conf` below, validation on
/// save. Prefilled from the saved config's canonical serialization
/// (`asConfString()`), which `ConfParser` round-trips. The parsed
/// draft is rebuilt with the tunnel's original `id`/`createdAt` so an
/// edit never changes identity or list order. Ghost mode is just text
/// here: adding or deleting the `[Wstunnel]` section converts the
/// tunnel between ghost and standalone WireGuard, through exactly the
/// same validation steps as import. Reachable only while the tunnel
/// is inactive.
struct TunnelEditView: View {
    var tunnel: TunnelContainer
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var rawInput: String
    @State private var errorMessages: [String] = []

    init(tunnel: TunnelContainer) {
        self.tunnel = tunnel
        let config = tunnel.tunnelConfig
        _name = State(initialValue: config?.name ?? tunnel.name)
        _rawInput = State(initialValue: config?.asConfString() ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            if !errorMessages.isEmpty {
                errorBanner
            }

            Form {
                nameSection
                rawInputSection
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)
        }
        .navigationTitle(loc.t("edit_title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(loc.t("edit_save")) { submit() }
                    .fontWeight(.semibold)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier(AXID.TunnelEdit.saveButton)
            }
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField(loc.t("import_name_placeholder"), text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(AXID.TunnelEdit.nameField)
        } header: {
            Label(loc.t("detail_name"), systemImage: "gearshape")
                .padding(.leading, 4)
        }
    }

    private var rawInputSection: some View {
        Section {
            TextEditor(text: $rawInput)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 220)
                .autocorrectionDisabled()
                .accessibilityIdentifier(AXID.TunnelEdit.confEditor)
        } header: {
            Label(loc.t("import_configuration"), systemImage: "doc.text")
                .padding(.leading, 4)
        } footer: {
            Text(loc.t("edit_footer"))
                .padding(.leading, 4)
        }
    }

    // MARK: - Error Banner

    private var errorBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(errorMessages, id: \.self) { message in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message)
                        .font(.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.gradient)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AXID.TunnelEdit.errorBanner)
    }

    // MARK: - Logic

    private var canSubmit: Bool {
        tunnel.status == .inactive
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        errorMessages = []

        // Identity anchor. Without a decodable saved config there is
        // nothing to edit against — the entry button is unreachable in
        // that state, so this is purely defensive.
        guard let original = tunnel.tunnelConfig else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInput = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            errorMessages = [loc.t("import_err_empty_name")]
            return
        }
        guard !trimmedInput.isEmpty else {
            errorMessages = [loc.t("parse_err_empty_input")]
            return
        }

        // Structural parse — produces a draft or throws a banner error.
        let parsed: TunnelDraft
        do {
            parsed = try ConfParser.parse(trimmedInput)
        } catch let error as ConfParser.ParseError {
            errorMessages = [ConfEditorMessages.parseMessage(error, loc: loc)]
            return
        } catch {
            errorMessages = [error.localizedDescription]
            return
        }

        // Re-anchor the parsed sections onto the tunnel's original
        // identity — `ConfParser` mints a fresh id/createdAt, but an
        // edit must not change either.
        let draft = TunnelDraft(
            id: original.id,
            name: trimmedName,
            createdAt: original.createdAt,
            wireguard: parsed.wireguard,
            wstunnel: parsed.wstunnel
        )

        // Field-level validation — identical steps and messages as
        // import, surfaced as a list in the banner.
        let result = draft.validate()
        guard let config = result.config else {
            errorMessages = ConfEditorMessages.fieldMessages(result.errors, loc: loc)
            return
        }

        Task {
            do {
                try await tunnelsManager.modify(tunnel: tunnel, with: config)
                dismiss()
            } catch {
                errorMessages = [error.localizedDescription]
            }
        }
    }
}

// MARK: - Previews

/// Fully interactive against the in-memory manager: reshape the
/// prefilled `.conf` (drop the `[Wstunnel]` block, break a key…) and
/// Save exercises the real parse → validate → modify chain.
#Preview {
    let manager = PreviewFixtures.tunnelsManager(providers: [
        PreviewFixtures.provider(config: PreviewFixtures.ghostConfig())
    ])
    return NavigationStack {
        TunnelEditView(tunnel: manager.tunnels[0])
    }
    .previewEnvironment(tunnels: manager)
    .frame(width: 480, height: 720)
}
