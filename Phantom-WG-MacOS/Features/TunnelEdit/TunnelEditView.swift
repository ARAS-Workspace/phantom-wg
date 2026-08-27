import SwiftUI

struct TunnelEditView: View {
    var tunnel: TunnelContainer
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(TunnelVaultClient.self) private var vault
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var rawInput: String = ""
    @State private var errorMessages: [String] = []

    @State private var original: TunnelConfig?
    @State private var loaded = false
    @State private var loadUnreachable = false
    @State private var saving = false

    init(tunnel: TunnelContainer) {
        self.tunnel = tunnel
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
        .task { await loadOriginal() }
    }

    private func loadOriginal() async {
        guard !loaded else { return }

        let result = await vault.read(id: tunnel.id, attempts: 3)
        loaded = true

        switch result {
        case .config(let config):
            original = config
            name = config.name
            rawInput = config.asConfString()
            loadUnreachable = false
            errorMessages = []
        case .unreachable:
            name = tunnel.name
            loadUnreachable = true
            errorMessages = [loc.t("detail_config_unreachable")]
        case .missing, .undecodable:
            name = tunnel.name
            loadUnreachable = false
            errorMessages = [loc.t("detail_config_unavailable")]
        }
    }

    private func retryLoad() async {
        loaded = false
        await loadOriginal()
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

            if loadUnreachable {
                Button(loc.t("detail_config_retry")) {
                    Task { await retryLoad() }
                }
                .controlSize(.small)
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
        original != nil
            && !saving
            && tunnel.isSettledInactive
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard !saving else { return }
        errorMessages = []

        guard let original else { return }

        // The gate is re-read at the moment of the click; a row that has
        // moved since the button was painted refuses here, before modify.
        guard tunnel.isSettledInactive else {
            errorMessages = [loc.t("edit_err_not_settled")]
            return
        }

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

        let draft = TunnelDraft(
            id: original.id,
            name: trimmedName,
            createdAt: original.createdAt,
            wireguard: parsed.wireguard,
            wstunnel: parsed.wstunnel
        )

        let result = draft.validate()
        guard let config = result.config else {
            errorMessages = ConfEditorMessages.fieldMessages(result.errors, loc: loc)
            return
        }

        saving = true
        Task {
            do {
                try await tunnelsManager.modify(tunnel: tunnel, with: config)
                dismiss()
            } catch {
                saving = false
                errorMessages = [error.localizedDescription]
            }
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    let manager = PreviewFixtures.tunnelsManager(providers: [
        PreviewFixtures.provider(config: PreviewFixtures.ghostConfig())
    ])
    return NavigationStack {
        TunnelEditView(tunnel: manager.tunnels[0])
    }
    .previewEnvironment(tunnels: manager, scheme: .light)
    .frame(width: 560, height: 720)
}

#Preview("Dark") {
    let manager = PreviewFixtures.tunnelsManager(providers: [
        PreviewFixtures.provider(config: PreviewFixtures.ghostConfig())
    ])
    return NavigationStack {
        TunnelEditView(tunnel: manager.tunnels[0])
    }
    .previewEnvironment(tunnels: manager, scheme: .dark)
    .frame(width: 560, height: 720)
}
