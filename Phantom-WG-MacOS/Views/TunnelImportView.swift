import SwiftUI

struct TunnelImportView: View {
    @EnvironmentObject var tunnelsManager: TunnelsManager
    @EnvironmentObject var loc: LocalizationManager
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.red.gradient)
                }

                Form {
                    Section {
                        TextEditor(text: $inputText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 150)
                            .autocorrectionDisabled()
                    } header: {
                        Label(loc.t("import_configuration"), systemImage: "doc.text")
                            .padding(.leading, 4)
                    } footer: {
                        Text(loc.t("import_footer"))
                            .padding(.leading, 4)
                    }

                    Section {
                        Button {
                            if let clipboard = NSPasteboard.general.string(forType: .string) {
                                inputText = clipboard
                                errorMessage = nil
                            }
                        } label: {
                            Label(loc.t("import_paste"), systemImage: "doc.on.clipboard")
                        }
                    } header: {
                        Label(loc.t("import_quick_actions"), systemImage: "bolt")
                            .padding(.leading, 4)
                    }
                }
                .formStyle(.grouped)
                .padding(.horizontal, 8)
            }
            .navigationTitle(loc.t("import_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.t("cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.t("import_button")) { importConfig() }
                        .fontWeight(.semibold)
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func importConfig() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var config: TunnelConfig
        do {
            config = try ConfigStore.decodeAndValidate(json: trimmed)
        } catch let error as ConfigStore.ValidationError {
            errorMessage = validationErrorMessage(error)
            return
        } catch {
            errorMessage = loc.t("import_invalid_format")
            return
        }

        config.id = UUID()

        Task {
            do {
                _ = try await tunnelsManager.add(config: config)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func validationErrorMessage(_ error: ConfigStore.ValidationError) -> String {
        switch error {
        case .emptyName:        return loc.t("import_err_empty_name")
        case .emptyWstunnelUrl: return loc.t("import_err_empty_wstunnel_url")
        case .emptyPrivateKey:  return loc.t("import_err_empty_private_key")
        case .emptyPublicKey:   return loc.t("import_err_empty_public_key")
        case .emptyAddress:     return loc.t("import_err_empty_address")
        case .emptyEndpoint:    return loc.t("import_err_empty_endpoint")
        case .invalidJson(let detail):
            return loc.t("import_err_invalid_json", detail)
        }
    }
}
