import Foundation
import AppKit
import SystemExtensions
import os.log

/// Aggregates the three `ExtensionGateController` instances that
/// represent the app's required system extensions and exposes a
/// single readiness signal the root view consumes.
///
/// `allReady` is the only gate that decides whether `PhantomApp` lets
/// the user past the extension panel and into the tunnel UI; if any
/// controller drops out of `.activated` (System Settings toggle off,
/// uninstall, replacement upgrade) the root view falls back to the
/// gate panel and the user is asked to bring it back.
///
/// The coordinator re-issues `checkAll()` whenever the app comes to
/// the foreground so a System Settings round-trip is reflected
/// without a manual refresh.
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

    /// Designated initializer with explicit controllers — previews
    /// inject controllers frozen at specific statuses through this.
    init(tunnel: ExtensionGateController, split: ExtensionGateController, dns: ExtensionGateController) {
        self.tunnel = tunnel
        self.split = split
        self.dns = dns
    }

    /// Production composition: the app's three system extensions.
    convenience init() {
        let loc = LocalizationManager.shared
        self.init(
            tunnel: ExtensionGateController(
                bundleID: "com.remrearas.Phantom-WG-MacOS.PhantomTunnel",
                displayName: loc.t("gate_ext_tunnel")
            ),
            split: ExtensionGateController(
                bundleID: "com.remrearas.Phantom-WG-MacOS.PhantomSplitTunnel",
                displayName: loc.t("gate_ext_split")
            ),
            dns: ExtensionGateController(
                bundleID: "com.remrearas.Phantom-WG-MacOS.PhantomDNSProxy",
                displayName: loc.t("gate_ext_dns")
            )
        )
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    /// All three extensions report `.activated`. Root switch keys off
    /// this single boolean.
    var allReady: Bool {
        controllers.allSatisfy { $0.status == .activated }
    }

    var controllers: [ExtensionGateController] {
        [tunnel, split, dns]
    }

    // MARK: - Lifecycle

    /// Boot-time wiring. Subscribes to `didBecomeActive` so the gate
    /// re-checks every extension when the user returns from System
    /// Settings, then submits an activation request for each
    /// controller. `activate()` is the more reliable boot signal:
    /// `propertiesRequest` returns an empty array for extensions
    /// that are registered but disabled in System Settings, while
    /// `activate()` resolves through `.completed` /
    /// `requestNeedsUserApproval` / `didFailWithError` and gives
    /// each controller enough context to settle on the right state.
    func start() {
        log("start() — boot activate for all controllers")
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
        for controller in controllers {
            controller.activate()
        }
    }

    // MARK: - Actions

    /// Pull ground-truth state from the OS for every controller. The
    /// top-level "Tekrar Kontrol Et" button and the foreground
    /// observer both bind to this; per-row buttons bind to the
    /// individual controller's `activate()`.
    func checkAll() {
        log("checkAll() — refresh all controllers (allReady=\(allReady))")
        for controller in controllers {
            controller.refresh()
        }
    }

    /// Sequential deactivation of all three extensions. Used by the
    /// settings menu's uninstall entry — the user removes the whole
    /// app from the system in one action. Failures bubble up so the
    /// caller can surface them; on success every controller settles
    /// to `.notInstalled` and the root view falls back to the gate.
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
}
