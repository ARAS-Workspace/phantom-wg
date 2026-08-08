import SwiftUI

/// Raw-paste import surface, pushed from the tunnel list like its
/// macOS counterpart. The user pastes a WireGuard `.conf` (or scans
/// a QR encoding one), enters a tunnel name, and imports. Structural
/// and field-level errors are surfaced in a single inline banner
/// above the inputs. Later edits go through `TunnelEditView` — the
/// same raw-text shape as this screen.
struct TunnelImportView: View {
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    @State private var tunnelName = ""
    @State private var inputText = ""
    @State private var errorMessages: [String] = []
    @State private var showingQRScanner = false

    private var canSubmit: Bool {
        !tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if !errorMessages.isEmpty {
                errorBanner
            }

            Form {
                nameSection
                rawInputSection
                quickActionsSection
            }
        }
        .navigationTitle(loc.t("import_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(loc.t("import_button")) { submit() }
                    .fontWeight(.semibold)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier(AXID.TunnelImport.submitButton)
            }
        }
        .sheet(isPresented: $showingQRScanner) {
            QRScannerView { scanned in
                showingQRScanner = false
                inputText = scanned
                submit()
            }
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField(loc.t("import_name_placeholder"), text: $tunnelName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier(AXID.TunnelImport.nameField)
        } header: {
            Label(loc.t("import_name_section"), systemImage: "tag")
        }
    }

    private var rawInputSection: some View {
        Section {
            TextEditor(text: $inputText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 150)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier(AXID.TunnelImport.confEditor)
        } header: {
            Label(loc.t("import_configuration"), systemImage: "doc.text")
        } footer: {
            Text(loc.t("import_footer"))
        }
    }

    private var quickActionsSection: some View {
        Section {
            Button {
                showingQRScanner = true
            } label: {
                Label(loc.t("import_scan_qr"), systemImage: "qrcode.viewfinder")
            }
            .accessibilityIdentifier(AXID.TunnelImport.qrScanButton)

            Button {
                if let clipboard = UIPasteboard.general.string {
                    inputText = clipboard
                    errorMessages = []
                }
            } label: {
                Label(loc.t("import_paste"), systemImage: "doc.on.clipboard")
            }
            .accessibilityIdentifier(AXID.TunnelImport.pasteButton)
        } header: {
            Label(loc.t("import_quick_actions"), systemImage: "bolt")
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

    // MARK: - Submit

    private func submit() {
        errorMessages = []

        let trimmedName = tunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            errorMessages = [loc.t("import_err_empty_name")]
            return
        }
        guard !trimmedInput.isEmpty else {
            errorMessages = [loc.t("parse_err_empty_input")]
            return
        }

        // Structural parse — produces a draft or throws a banner error.
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

        // Field-level validation — all failures are surfaced as a list
        // in the banner; the form itself never appears during import.
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
    .previewEnvironment(scheme: .light)
}

#Preview("Dark") {
    NavigationStack {
        TunnelImportView()
    }
    .previewEnvironment(scheme: .dark)
}
