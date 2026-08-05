import Foundation
import SystemExtensions
import os.log

/// Generic activation / approval / deactivation surface for a single
/// system extension bundle. One instance per extension; the app's
/// three extensions (Tunnel / Split-Tunnel / DNSProxy) each own their
/// own controller and the `ExtensionGateCoordinator` aggregates them.
///
/// The controller interprets every `OSSystemExtensionRequest` signal
/// Apple emits — `propertiesRequest`, `requestNeedsUserApproval`,
/// `didFinishWithResult`, `didFailWithError` — and projects them onto
/// a single `Status` enum the gate UI consumes. Behaviour mirrors what
/// is required to be battle-tested across the user-driven scenarios:
/// cold boot with the extension already enabled, fresh install,
/// installed-but-disabled-in-System-Settings, replacement upgrade,
/// uninstall, and every documented `OSSystemExtensionError` code.
///
/// State changes are user-driven: every transition is the result of
/// a button press (`activate()` / `refresh()` / `deactivate()`) or a
/// delegate callback. There is no background polling and no
/// notification observer; the coordinator re-checks on app foreground
/// for runtime drop-back detection.
@Observable
@MainActor
final class ExtensionGateController: NSObject, OSSystemExtensionRequestDelegate {

    enum Status: Equatable {
        case unknown
        case notInstalled
        case activating
        case needsApproval
        case activated
        case failed(String)
    }

    let bundleID: String
    let displayName: String

    private(set) var status: Status = .unknown

    @ObservationIgnored private var deactivationContinuation: CheckedContinuation<Void, Error>?

    /// True between an activation request resolving `.completed` and
    /// the follow-up `propertiesRequest` arriving. Apple returns an
    /// empty `propertiesRequest` array for extensions that are
    /// registered but disabled in System Settings (toggle off), which
    /// is indistinguishable from "truly not installed" without this
    /// hint — `.completed` only fires when the extension is known to
    /// the system, so an empty reply in that window means the user
    /// must re-enable it in Settings.
    @ObservationIgnored private var pendingActivationCompleted = false

    /// Count of activation requests submitted and not yet resolved by
    /// a terminal callback (`didFinishWithResult` / `didFailWithError`).
    /// While non-zero, `foundProperties` must not promote to
    /// `.activated`: during a replacement the properties query happily
    /// reports the outgoing extension as enabled, and an early
    /// promotion reopens the gate while the provider kill is still in
    /// flight (field-measured: `allReady` flipped, downstream boot
    /// logic ran, and `stopTunnel` landed moments later). The
    /// promotion belongs to the completion path — `didFinishWithResult`
    /// → `refresh()` → here, with this counter back at zero. A counter
    /// rather than a flag so a second `activate()` superseding the
    /// first keeps its own protection when the first request's failure
    /// callback lands.
    @ObservationIgnored private var activationsInFlight = 0

    @ObservationIgnored private let oslog: OSLog

    /// Production always starts at `.unknown` and lets the delegate
    /// callbacks settle the real state; previews pass a fixed `status`
    /// to render a specific gate scenario.
    init(bundleID: String, displayName: String, status: Status = .unknown) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.oslog = OSLog(
            subsystem: "com.remrearas.Phantom-WG-MacOS",
            category: "gate.\(displayName)"
        )
        self.status = status
        super.init()
    }

    private func log(_ message: String) {
        os_log("%{public}@", log: oslog, type: .default, message)
    }

    // MARK: - Public Surface

    /// Submit an activation request. Idempotent at the OS level: if
    /// the extension isn't built yet macOS installs it, if approval
    /// is missing macOS surfaces the prompt, if everything is in
    /// place the request resolves immediately. The follow-up
    /// `propertiesRequest` is the authority on actual enabled state
    /// because Apple resolves `.completed` even for installed-but-
    /// disabled extensions.
    func activate() {
        log("activate() submitted (bundleID=\(bundleID), status=\(status))")
        pendingActivationCompleted = false
        activationsInFlight += 1
        if status != .needsApproval {
            status = .activating
        }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: bundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Pull ground-truth state from the OS. The delegate writes the
    /// reply into `status` via `request(_:foundProperties:)`.
    func refresh() {
        log("refresh() submitted (status=\(status))")
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: bundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Submit a deactivation request and await completion. Throws on
    /// hard error, resolves to `.notInstalled` on success.
    func deactivate() async throws {
        log("deactivate() submitted (status=\(status))")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.deactivationContinuation = continuation
            let request = OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: bundleID,
                queue: .main
            )
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private func resumeDeactivation(with result: Result<Void, Error>) {
        guard let continuation = deactivationContinuation else { return }
        deactivationContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: - OSSystemExtensionRequestDelegate

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        Task { @MainActor in
            log("actionForReplacingExtension: \(existing.bundleShortVersion) → \(ext.bundleShortVersion)")
        }
        return .replace
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        Task { @MainActor in
            // `propertiesRequest` returns *every* extension version
            // the system has seen for this bundle ID — including
            // historical orphans that are still draining out of the
            // system extension store. Those carry `isUninstalling =
            // true`. The live version (if any) is the one with
            // `isUninstalling = false`; orphans must be filtered out
            // before any flag is interpreted.
            let live = properties.filter { !$0.isUninstalling }
            log("foundProperties total=\(properties.count) live=\(live.count) pending=\(pendingActivationCompleted) status=\(status)")
            let pending = pendingActivationCompleted
            pendingActivationCompleted = false

            guard let liveProp = pickLive(from: live) else {
                // No live entry — every property is an orphan being
                // uninstalled, or the array is empty. Right after
                // an activation request resolved `.completed` the
                // extension is known to the system, so this window
                // means the user has it disabled in System Settings.
                // Outside that window the cold boot `.unknown`
                // snapshot is taken as "truly not installed";
                // otherwise it is a transient OS query lag.
                if pending {
                    log("→ no live entry + pending → .needsApproval (installed-but-disabled)")
                    status = .needsApproval
                } else if status == .unknown {
                    log("→ no live entry + unknown → .notInstalled")
                    status = .notInstalled
                } else {
                    log("→ no live entry + status=\(status) → no-op (transient)")
                }
                return
            }

            log("→ live: isEnabled=\(liveProp.isEnabled),isAwaiting=\(liveProp.isAwaitingUserApproval),v\(liveProp.bundleShortVersion)")

            if liveProp.isAwaitingUserApproval {
                log("→ live.isAwaitingUserApproval=true → .needsApproval")
                status = .needsApproval
                return
            }
            if liveProp.isEnabled {
                // Only the promotion is held — `.needsApproval` /
                // `.notInstalled` transitions above stay live so the
                // approval flow never deadlocks on this counter.
                guard activationsInFlight == 0 else {
                    log("→ live.isEnabled=true, activation in flight → holding \(status)")
                    return
                }
                log("→ live.isEnabled=true → .activated")
                status = .activated
            } else {
                // Live entry exists but is disabled in System
                // Settings. The activation API cannot re-enable it;
                // the user must flip the toggle themselves, so the
                // gate guides them to System Settings.
                log("→ live.isEnabled=false → .needsApproval (toggle off)")
                status = .needsApproval
            }
        }
    }

    /// Picks the most authoritative live entry from a non-orphan
    /// subset. Apple may report duplicate live versions during a
    /// replacement upgrade; preferring `isEnabled` then
    /// `isAwaitingUserApproval` makes the chosen entry reflect the
    /// version the system is actually running.
    private func pickLive(from live: [OSSystemExtensionProperties]) -> OSSystemExtensionProperties? {
        if let enabled = live.first(where: { $0.isEnabled }) {
            return enabled
        }
        if let awaiting = live.first(where: { $0.isAwaitingUserApproval }) {
            return awaiting
        }
        return live.first
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            log("requestNeedsUserApproval → .needsApproval")
            status = .needsApproval
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            log("didFinishWithResult: \(result.rawValue) (deactivating=\(deactivationContinuation != nil))")
            if deactivationContinuation != nil {
                status = .notInstalled
                resumeDeactivation(with: .success(()))
                return
            }
            activationsInFlight = max(0, activationsInFlight - 1)
            switch result {
            case .completed:
                // `.completed` only signals that the activation
                // request finished — Apple resolves it even when the
                // extension is installed but disabled. The properties
                // query is the authority on whether the gate should
                // advance, so re-issue it and let `foundProperties`
                // drive the final state. The `pendingActivationCompleted`
                // hint is what disambiguates an empty reply in that
                // window from "truly not installed".
                pendingActivationCompleted = true
                refresh()
            case .willCompleteAfterReboot:
                status = .needsApproval
            @unknown default:
                refresh()
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
        Task { @MainActor in
            log("didFailWithError: domain=\(domain) code=\(code) — \(error.localizedDescription)")
            if deactivationContinuation != nil {
                resumeDeactivation(with: .failure(error))
                return
            }
            activationsInFlight = max(0, activationsInFlight - 1)
            guard domain == OSSystemExtensionErrorDomain else {
                status = .failed(error.localizedDescription)
                return
            }
            handleActivationFailure(code: code, error: error)
        }
    }

    // MARK: - Failure Mapping

    private func handleActivationFailure(code: Int, error: Error) {
        let loc = LocalizationManager.shared
        switch OSSystemExtensionError.Code(rawValue: code) {
        case .requestCanceled, .requestSuperseded:
            log("→ requestCanceled/Superseded — no-op")
            return
        case .authorizationRequired:
            log("→ authorizationRequired → .needsApproval")
            status = .needsApproval
        case .extensionNotFound:
            log("→ extensionNotFound → .notInstalled")
            status = .notInstalled
        case .unsupportedParentBundleLocation:
            log("→ unsupportedParentBundleLocation → .failed")
            status = .failed(loc.t("sysext_err_unsupported_location"))
        case .codeSignatureInvalid:
            log("→ codeSignatureInvalid → .failed")
            status = .failed(loc.t("sysext_err_code_signature"))
        case .validationFailed:
            log("→ validationFailed → .failed")
            status = .failed(loc.t("sysext_err_validation"))
        case .forbiddenBySystemPolicy:
            log("→ forbiddenBySystemPolicy → .failed")
            status = .failed(loc.t("sysext_err_system_policy"))
        case .missingEntitlement:
            log("→ missingEntitlement → .failed")
            status = .failed(loc.t("sysext_err_entitlement"))
        default:
            log("→ unknown sysext error code \(code) → .failed")
            status = .failed(loc.t("sysext_err_unknown", code, error.localizedDescription))
        }
    }
}
