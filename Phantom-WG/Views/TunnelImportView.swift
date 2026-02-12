import SwiftUI

struct TunnelImportView: View {
    @EnvironmentObject var tunnelsManager: TunnelsManager
    @EnvironmentObject var loc: LocalizationManager
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var errorMessage: String?
    @State private var showingQRScanner = false

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
                            .textInputAutocapitalization(.never)
                    } header: {
                        Label(loc.t("import_configuration"), systemImage: "doc.text")
                    } footer: {
                        Text(loc.t("import_footer"))
                    }

                    Section {
                        Button {
                            showingQRScanner = true
                        } label: {
                            Label(loc.t("import_scan_qr"), systemImage: "qrcode.viewfinder")
                        }

                        Button {
                            if let clipboard = UIPasteboard.general.string {
                                inputText = clipboard
                                errorMessage = nil
                            }
                        } label: {
                            Label(loc.t("import_paste"), systemImage: "doc.on.clipboard")
                        }
                    } header: {
                        Label(loc.t("import_quick_actions"), systemImage: "bolt")
                    }
                }
            }
            .navigationTitle(loc.t("import_title"))
            .navigationBarTitleDisplayMode(.inline)
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
            .sheet(isPresented: $showingQRScanner) {
                QRScannerView { scanned in
                    showingQRScanner = false
                    inputText = scanned
                    importConfig()
                }
            }
        }
    }

    private func importConfig() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let jsonData = trimmed.data(using: .utf8) else {
            errorMessage = loc.t("import_invalid_input")
            return
        }

        guard var config = try? JSONDecoder().decode(TunnelConfig.self, from: jsonData) else {
            errorMessage = loc.t("import_invalid_format")
            return
        }

        config.id = UUID()  // Always new ID on import

        Task {
            do {
                _ = try await tunnelsManager.add(config: config, activateOnDemand: .off)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}