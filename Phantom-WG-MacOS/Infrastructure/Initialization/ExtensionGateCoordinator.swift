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
    @ObservationIgnored private var workspaceEcho: WorkspaceEcho?
    /// The echo's second measurement, held so a burst of transitions
    /// collapses into one rather than queueing a probe per callback.
    @ObservationIgnored private var pendingEchoRecheck: Task<Void, Never>?

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
    /// session uses — one endpoint serves both locks, no separate
    /// identity RPC exists on the vault daemon; an answer proves
    /// liveness whatever the vault door says.
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
        // Push-side of the gate: the workspace notifies enable/disable/
        // deactivate transitions the moment they happen, killing the
        // one blind spot the foreground re-check had — a System
        // Settings toggle flipped while this app stays frontmost was
        // invisible until the next focus change. The observer scope is
        // not documented as app-limited, so transitions are filtered
        // to our own extensions; the foreground re-check above stays
        // as the belt for everything else. macOS offers no workspace
        // QUERY, so `checkAll`/`settle` remain the measurement — this
        // only sharpens when they run.
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

    /// Pull ground-truth state from the OS for every controller. The
    /// top-level check-again button (`gate_check_again`) and the
    /// foreground observer both bind to this; per-row buttons bind to the
    /// individual controller's `activate()`. Controllers still inside
    /// their boot measurement are skipped — the settle tree owns the
    /// verdict until it returns.
    func checkAll() {
        // Counted rather than announced. The line used to say "refresh
        // all controllers" over a loop that skips anything still inside
        // its boot measurement — and at boot that is every one of them,
        // so the log claimed three refreshes where none were issued.
        // The filter arrived a commit after the sentence and the
        // sentence never caught up.
        let due = controllers.filter { !$0.isSettling }
        log("checkAll() — refreshing \(due.count)/\(controllers.count), "
            + "\(controllers.count - due.count) still settling (allReady=\(allReady))")
        for controller in due {
            controller.refresh()
        }
    }

    /// Sequential deactivation of all three extensions. Used by the
    /// settings menu's uninstall entry — the flow takes down what the
    /// SYSTEM holds (extensions, this user's VPN entries) while
    /// configurations and keys stay by contract. Failures bubble up
    /// so the caller can surface them; on success every controller
    /// settles to `.notInstalled` and the root view falls back to the
    /// gate.
    /// Sequential, and it throws on the first refusal — so a teardown
    /// that fails partway leaves the later extensions installed and the
    /// user is told only why it stopped, never how far it got.
    ///
    /// Named rather than fixed, because the alternative is a product
    /// decision and not a correction: continuing past a failure would
    /// take extensions down that the user has no reason to expect gone
    /// after being shown an error. What the sequence does buy is the
    /// bound on the worst case — each wait carries its own budget, and
    /// stopping at the first means one budget can be spent here, not
    /// three.
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

    /// The echo's callbacks are WILL-transitions: the workspace names
    /// the change before it is committed, so the measurement the first
    /// `checkAll` takes can still read the world as it was. That is not
    /// a flaw in the callback, it is what "will" means — but it undoes
    /// the one blind spot this observer exists to close, since a
    /// Settings toggle flipped while the app stays frontmost has no
    /// second trigger behind it.
    ///
    /// So the transition is measured TWICE: once now, which is right
    /// whenever the commit has already landed, and once past it. The
    /// task is held and cancelled on each new transition because macOS
    /// delivers these in bursts — three extensions changing together is
    /// the ordinary case here — and one settled measurement answers for
    /// all of them.
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

/// The workspace observer's landing pad. A separate NSObject on
/// purpose: `OSSystemExtensionsWorkspaceObserver` requires one, and
/// the coordinator should not inherit NSObject just to hear these.
/// Callbacks arrive on an unspecified queue and are forwarded only
/// for this app's own extensions — the workspace's observer scope is
/// not documented as app-limited.
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
