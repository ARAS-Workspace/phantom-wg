import SwiftUI

struct TunnelListView: View {
    @EnvironmentObject var tunnelsManager: TunnelsManager
    @EnvironmentObject var loc: LocalizationManager
    @State private var showingImport = false
    @State private var errorMessage: String?
    @State private var showingError = false

    private var canModifyList: Bool {
        PhantomUIEngine.canModifyTunnelList(statuses: tunnelsManager.tunnels.map(\.status))
    }

    var body: some View {
        NavigationStack {
            Group {
                if tunnelsManager.tunnels.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(tunnelsManager.tunnels) { tunnel in
                            NavigationLink(destination: TunnelDetailView(tunnel: tunnel)) {
                                TunnelRow(tunnel: tunnel)
                            }
                        }
                        .onDelete { offsets in deleteTunnels(at: offsets) }
                        .deleteDisabled(!canModifyList)

                        aboutSection
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle(loc.t("app_title"))
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        loc.current = loc.current == .tr ? .en : .tr
                    } label: {
                        Text(loc.current == .tr ? LocalizationManager.Language.en.flag : LocalizationManager.Language.tr.flag)
                            .font(.title2)
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingImport = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!canModifyList)
                }
            }
            .sheet(isPresented: $showingImport) {
                TunnelImportView()
            }
            .alert(loc.t("error"), isPresented: $showingError) {
                Button(loc.t("ok")) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("PhantomLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .opacity(0.35)

            VStack(spacing: 8) {
                Text(loc.t("tunnel_list_empty_title"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(loc.t("tunnel_list_empty_description"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showingImport = true
            } label: {
                Label(loc.t("import_title"), systemImage: "plus.circle.fill")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(!canModifyList)

            Spacer()

            HStack(spacing: 24) {
                NavigationLink {
                    AboutView()
                } label: {
                    Label(loc.t("about_title"), systemImage: "info.circle")
                        .font(.footnote)
                }
                Link(destination: URL(string: "https://www.phantom.tc")!) {
                    Label(loc.t("website"), systemImage: "globe")
                        .font(.footnote)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 20)
        }
        .padding()
    }

    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutView()
            } label: {
                Label(loc.t("about_title"), systemImage: "info.circle")
            }
            Link(destination: URL(string: "https://www.phantom.tc")!) {
                Label(loc.t("website"), systemImage: "globe")
            }
        }
    }

    private func deleteTunnels(at offsets: IndexSet) {
        let tunnelsToDelete = offsets.map { tunnelsManager.tunnels[$0] }
        for tunnel in tunnelsToDelete {
            if tunnel.status != .inactive {
                tunnelsManager.startDeactivation(of: tunnel)
            }
            Task {
                do {
                    try await tunnelsManager.remove(tunnel: tunnel)
                } catch {
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            }
        }
    }
}

// MARK: - Tunnel Row

struct TunnelRow: View {
    @ObservedObject var tunnel: TunnelContainer
    @EnvironmentObject var tunnelsManager: TunnelsManager
    @EnvironmentObject var loc: LocalizationManager

    var body: some View {
        HStack(spacing: 12) {
            statusIndicator

            VStack(alignment: .leading, spacing: 3) {
                Text(tunnel.name)
                    .font(.body.weight(.medium))
                Text(tunnel.status.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: PhantomUIEngine.tunnelToggleBinding(for: tunnel, manager: tunnelsManager))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private var statusIndicator: some View {
        let color = PhantomUIEngine.statusColor(for: tunnel.status)
        return ZStack {
            Circle()
                .fill(color.opacity(0.15))
                .frame(width: 32, height: 32)
            Image(systemName: PhantomUIEngine.statusIcon(for: tunnel.status))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}
