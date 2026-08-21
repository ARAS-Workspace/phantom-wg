import Foundation
import AppKit
import SystemExtensions
import os.log

@Observable
@MainActor
final class ExtensionGateCoordinator {

    let tunnel: ExtensionGateController
    let split: ExtensionGateController
    let dns: ExtensionGateController

    @ObservationIgnored private let oslog = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS",
        category: "gate.coordinator"
    )
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var workspaceEcho: WorkspaceEcho?
    @ObservationIgnored private var pendingEchoRecheck: Task<Void, Never>?

    @ObservationIgnored private var hasRunBootMeasurement = false

    init(tunnel: ExtensionGateController, split: ExtensionGateController, dns: ExtensionGateController) {
        self.tunnel = tunnel
        self.split = split
        self.dns = dns
    }

    convenience init(
        vault: TunnelVaultClient,
        splitDaemon: SplitTunnelDaemonClient,
        dnsDaemon: DNSProxyDaemonClient
    ) {
        let loc = LocalizationManager.shared
        self.init(
            tunnel: ExtensionGateController(
                bundleID: "com.remrearas.Phantom-WG-MacOS.PhantomTunnel",
                displayName: loc.t("gate_ext_tunnel"),
                identityProbe: {
                    switch await vault.ping() {
                    case .ready(_, let identity), .doorFailed(let identity):
                        return identity
                    case .unreachable:
                        return nil
                    }
                }
            ),
            split: ExtensionGateController(
                bundleID: "com.remrearas.Phantom-WG-MacOS.PhantomSplitTunnel",
                displayName: loc.t("gate_ext_split"),
                identityProbe: { await splitDaemon.identity() }
            ),
            dns: ExtensionGateController(
                bundleID: "com.remrearas.Phantom-WG-MacOS.PhantomDNSProxy",
                displayName: loc.t("gate_ext_dns"),
                identityProbe: { await dnsDaemon.identity() }
            )
        )
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        if let workspaceEcho {
            OSSystemExtensionsWorkspace.shared.removeObserver(workspaceEcho)
        }
        pendingEchoRecheck?.cancel()
    }

    var allReady: Bool {
        controllers.allSatisfy { $0.status == .activated }
    }

    var controllers: [ExtensionGateController] {
        [tunnel, split, dns]
    }

    // MARK: - Lifecycle

    func start() {
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.log("didBecomeActive → checkAll()")
                    self?.checkAll()
                }
            }
        }
        if workspaceEcho == nil {
            let echo = WorkspaceEcho { [weak self] bundleID in
                Task { @MainActor in
                    guard let self else { return }
                    self.log("workspace transition (\(bundleID)) → checkAll()")
                    self.checkAll()
                    self.scheduleEchoRecheck(for: bundleID)
                }
            }
            do {
                try OSSystemExtensionsWorkspace.shared.addObserver(echo)
                workspaceEcho = echo
            } catch {
                log("workspace observer registration failed: \(error.localizedDescription) — foreground re-checks carry the load alone")
            }
        }
        guard !hasRunBootMeasurement else {
            log("start() — boot measurement already run → checkAll()")
            checkAll()
            return
        }
        hasRunBootMeasurement = true
        log("start() — measured settle for all controllers")
        for controller in controllers {
            Task { await controller.settle() }
        }
    }

    // MARK: - Actions

    func checkAll() {
        let due = controllers.filter { !$0.isSettling }
        log("checkAll() — refreshing \(due.count)/\(controllers.count), "
            + "\(controllers.count - due.count) still settling (allReady=\(allReady))")
        for controller in due {
            controller.refresh()
        }
    }

    func uninstallAll() async throws {
        log("uninstallAll() — sequential deactivate")
        try await tunnel.deactivate()
        try await split.deactivate()
        try await dns.deactivate()
    }

    // MARK: - Logging

    private func log(_ message: String) {
        os_log("%{public}@", log: oslog, type: .default, message)
    }

    private func scheduleEchoRecheck(for bundleID: String) {
        pendingEchoRecheck?.cancel()
        pendingEchoRecheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.log("workspace transition (\(bundleID)) → second measurement, past the commit")
            self.checkAll()
        }
    }
}

private final class WorkspaceEcho: NSObject, OSSystemExtensionsWorkspaceObserver {

    private let onTransition: @Sendable (String) -> Void

    init(onTransition: @escaping @Sendable (String) -> Void) {
        self.onTransition = onTransition
    }

    private func forward(_ info: OSSystemExtensionInfo) {
        guard info.bundleIdentifier.hasPrefix("com.remrearas.Phantom-WG-MacOS.") else { return }
        onTransition(info.bundleIdentifier)
    }

    func systemExtensionWillBecomeEnabled(_ systemExtensionInfo: OSSystemExtensionInfo) {
        forward(systemExtensionInfo)
    }

    func systemExtensionWillBecomeDisabled(_ systemExtensionInfo: OSSystemExtensionInfo) {
        forward(systemExtensionInfo)
    }

    func systemExtensionWillBecomeInactive(_ systemExtensionInfo: OSSystemExtensionInfo) {
        forward(systemExtensionInfo)
    }
}
