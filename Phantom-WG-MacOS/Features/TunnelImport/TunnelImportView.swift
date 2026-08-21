import SwiftUI

struct TunnelImportView: View {
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var rawInput: String = ""
    @State private var errorMessages: [String] = []

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
        .navigationTitle(loc.t("import_title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(loc.t("import_button")) { submit() }
                    .fontWeight(.semibold)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier(AXID.TunnelImport.submitButton)
            }
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField(loc.t("import_name_placeholder"), text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(AXID.TunnelImport.nameField)
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
                .accessibilityIdentifier(AXID.TunnelImport.confEditor)

            Button {
                if let clipboard = NSPasteboard.general.string(forType: .string) {
                    rawInput = clipboard
                }
            } label: {
                Label(loc.t("import_paste"), systemImage: "doc.on.clipboard")
            }
            .accessibilityIdentifier(AXID.TunnelImport.pasteButton)
        } header: {
            Label(loc.t("import_configuration"), systemImage: "doc.text")
                .padding(.leading, 4)
        } footer: {
            Text(loc.t("import_footer"))
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
        .accessibilityIdentifier(AXID.TunnelImport.errorBanner)
    }

    // MARK: - Logic

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        errorMessages = []

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

        var draft: TunnelDraft
        do {
            draft = try ConfParser.parse(trimmedInput)
        } catch let error as ConfParser.ParseError {
            errorMessages = [ConfEditorMessages.parseMessage(error, loc: loc)]
            return
        } catch {
            errorMessages = [error.localizedDescription]
            return
        }
        draft.name = trimmedName

        let result = draft.validate()
        guard let config = result.config else {
            errorMessages = ConfEditorMessages.fieldMessages(result.errors, loc: loc)
            return
        }

        Task {
            do {
                _ = try await tunnelsManager.add(config: config)
                dismiss()
            } catch {
                errorMessages = [error.localizedDescription]
            }
        }
    }

}

// MARK: - Previews

#Preview("Light") {
    NavigationStack {
        TunnelImportView()
    }
    .previewEnvironment(tunnels: PreviewFixtures.tunnelsManager(providers: []), scheme: .light)
    .frame(width: 560, height: 720)
}

#Preview("Dark") {
    NavigationStack {
        TunnelImportView()
    }
    .previewEnvironment(tunnels: PreviewFixtures.tunnelsManager(providers: []), scheme: .dark)
    .frame(width: 560, height: 720)
}
