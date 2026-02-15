import SwiftUI
import SystemExtensions
import NetworkExtension

@main
struct PhantomApp: App {

    /// Test ortamında system extension aktivasyonunu atlar.
    /// Skips system extension activation in the test environment.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    @StateObject private var extensionState = SystemExtensionState()
    @StateObject private var tunnelsManager = TunnelsManagerLoader()
    @StateObject private var loc = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            Group {
                switch extensionState.status {
                case .unknown, .activating:
                    extensionActivatingView

                case .needsApproval:
                    extensionApprovalView

                case .activated:
                    tunnelContentView

                case .failed(let message):
                    extensionFailedView(message)
                }
            }
            .environmentObject(loc)
            .tint(Color.accentColor)
            .frame(width: 420, height: 640)
            .onAppear {
                guard !PhantomApp.isRunningTests else {
                    extensionState.status = .activated
                    return
                }
                extensionState.activate()
            }
        }
        .windowResizability(.contentSize)
    }

    private var approvalMessage: String {
        if #available(macOS 15.0, *) {
            return loc.t("sysext_approval_message_sequoia")
        } else {
            return loc.t("sysext_approval_message_sonoma")
        }
    }

    // MARK: - Extension States

    private var extensionActivatingView: some View {
        VStack(spacing: 20) {
            Image("PhantomLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
            ProgressView(loc.t("sysext_activating"))
                .tint(.secondary)
        }
    }

    private var extensionApprovalView: some View {
        VStack(spacing: 20) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text(loc.t("sysext_approval_title"))
                .font(.headline)

            Text(.init(approvalMessage))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(loc.t("sysext_open_settings")) {
                if #available(macOS 15.0, *) {
                    // Sequoia+: Login Items & Extensions → Network Extensions
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                } else {
                    // Sonoma: Privacy & Security → Extensions
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            }
            .buttonStyle(.borderedProminent)

            Button(loc.t("sysext_check_again")) {
                extensionState.activate()
            }
            .buttonStyle(.bordered)
        }
    }

    private var tunnelContentView: some View {
        Group {
            if let manager = tunnelsManager.manager {
                TunnelListView()
                    .environmentObject(manager)
            } else if let error = tunnelsManager.loadError {
                ContentUnavailableView(
                    loc.t("error"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                VStack(spacing: 20) {
                    Image("PhantomLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                    ProgressView(loc.t("app_loading"))
                        .tint(.secondary)
                }
                .task { await tunnelsManager.load() }
            }
        }
    }

    private func extensionFailedView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text(loc.t("sysext_failed_title"))
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(loc.t("sysext_retry")) {
                extensionState.activate()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Tunnels Manager Loader

@MainActor
class TunnelsManagerLoader: ObservableObject {
    @Published var manager: TunnelsManager?
    @Published var loadError: String?

    func load() async {
        do {
            manager = try await TunnelsManager.create()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - System Extension State

@MainActor
class SystemExtensionState: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {

    enum Status: Equatable {
        case unknown
        case activating
        case needsApproval
        case activated
        case failed(String)
    }

    @Published var status: Status = .unknown

    private static let extensionBundleId = "com.remrearas.Phantom-WG-MacOS.PhantomTunnel"
    private var approvalPollTask: Task<Void, Never>?

    func activate() {
        stopApprovalPolling()
        status = .activating
        NSLog("[SysExt] Activating: \(Self.extensionBundleId)")

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleId,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - Approval Polling

    private func startApprovalPolling() {
        stopApprovalPolling()
        approvalPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch { return }
                guard let self, self.status == .needsApproval else { return }
                NSLog("[SysExt] Polling: re-submitting activation request")
                self.activate()
            }
        }
    }

    private func stopApprovalPolling() {
        approvalPollTask?.cancel()
        approvalPollTask = nil
    }

    // MARK: - OSSystemExtensionRequestDelegate

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        NSLog("[SysExt] Replacing existing extension (v\(existing.bundleShortVersion) → v\(ext.bundleShortVersion))")
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        NSLog("[SysExt] Needs user approval")
        Task { @MainActor in
            status = .needsApproval
            startApprovalPolling()
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        NSLog("[SysExt] Finished with result: \(result.rawValue)")
        Task { @MainActor in
            stopApprovalPolling()
            switch result {
            case .completed:
                status = .activated
            case .willCompleteAfterReboot:
                NSLog("[SysExt] Will complete after reboot")
                status = .needsApproval
            @unknown default:
                status = .activated
            }
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        let nsError = error as NSError
        let code = nsError.code
        let domain = nsError.domain
        NSLog("[SysExt] Failed: domain=\(domain) code=\(code) — \(error.localizedDescription)")

        Task { @MainActor in
            stopApprovalPolling()

            guard domain == OSSystemExtensionErrorDomain else {
                status = .failed(error.localizedDescription)
                return
            }

            switch OSSystemExtensionError.Code(rawValue: code) {
            case .requestCanceled, .requestSuperseded:
                // Expected during polling — ignore silently
                NSLog("[SysExt] Request canceled/superseded, ignoring")
                return
            case .authorizationRequired:
                status = .needsApproval
                startApprovalPolling()
                return
            case .unsupportedParentBundleLocation:
                status = .failed("The app must be in /Applications to install the system extension.")
            case .extensionNotFound:
                status = .failed("System extension bundle not found inside the app.")
            case .codeSignatureInvalid:
                status = .failed("Code signature is invalid. The app may need to be re-signed.")
            case .validationFailed:
                status = .failed("System extension validation failed. Check entitlements and provisioning profile.")
            case .forbiddenBySystemPolicy:
                status = .failed("Blocked by system policy. Check System Settings → Privacy & Security.")
            case .missingEntitlement:
                status = .failed("Missing entitlement. The app may need to be re-signed.")
            default:
                status = .failed("System extension error (code \(code)): \(error.localizedDescription)")
            }
        }
    }
}
