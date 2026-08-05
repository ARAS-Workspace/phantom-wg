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

    /// One boot measurement per process. The window's `onAppear`
    /// re-runs `start()` on every re-creation, so without this guard
    /// each Dock-click reopen would re-measure — harmless but noisy —
    /// and, on the fallback paths, resubmit activations that tear
    /// down running tunnel sessions (field-measured: the OS stages a
    /// full replacement even for a byte-identical bundle and kills
    /// every live provider). Later calls fall through to `checkAll()`
    /// — the read-only path; re-activation stays a user action on the
    /// gate panel's buttons.
    @ObservationIgnored private var hasRunBootMeasurement = false

    /// Designated initializer with explicit controllers — previews
    /// inject controllers frozen at specific statuses through this.
    init(tunnel: ExtensionGateController, split: ExtensionGateController, dns: ExtensionGateController) {
        self.tunnel = tunnel
        self.split = split
        self.dns = dns
    }

    /// Production composition: the app's three system extensions,
    /// each with its own identity probe. One signal per extension, no
    /// cross-inference — the daemons live and die independently. The
    /// tunnel probe rides the same `pingIdentity` endpoint the vault
    /// session uses, so the launch path never asks that daemon twice;
    /// an answer proves liveness whatever the vault door says.
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
    /// Settings, then runs the measured settle on each controller:
    /// probe the extension's daemon for its build identity and
    /// activate only when the measurement demands it — see
    /// `ExtensionGateController.settle()` for the tree. The
    /// measurement runs once per process; window re-creations
    /// re-enter here via `onAppear` and drop to `checkAll()`.
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

    /// Pull ground-truth state from the OS for every controller. The
    /// top-level "Tekrar Kontrol Et" button and the foreground
    /// observer both bind to this; per-row buttons bind to the
    /// individual controller's `activate()`. Controllers still inside
    /// their boot measurement are skipped — the settle tree owns the
    /// verdict until it returns.
    func checkAll() {
        log("checkAll() — refresh all controllers (allReady=\(allReady))")
        for controller in controllers where !controller.isSettling {
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
