import Foundation
import SystemExtensions
import os.log

protocol SystemExtensionSubmitting {
    func submit(_ request: OSSystemExtensionRequest)
}

struct RealSystemExtensionSubmitter: SystemExtensionSubmitting {
    func submit(_ request: OSSystemExtensionRequest) {
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

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

    typealias IdentityProbe = @MainActor () async -> String?

    let bundleID: String
    let displayName: String

    private(set) var status: Status = .unknown

    private(set) var isSettling = false

    @ObservationIgnored private var deactivationContinuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var deactivationRequest: OSSystemExtensionRequest?
    @ObservationIgnored private var deactivationDeadline: Task<Void, Never>?
    @ObservationIgnored private var abandonedDeactivations: Set<ObjectIdentifier> = []

    @ObservationIgnored private let identityProbe: IdentityProbe?

    @ObservationIgnored private let submitter: SystemExtensionSubmitting

    @ObservationIgnored private var settleContinuation: CheckedContinuation<PropsVerdict, Never>?
    @ObservationIgnored private var settlePropsRequest: OSSystemExtensionRequest?

    private enum PropsVerdict {
        case noLive
        case awaiting
        case enabled
        case inconclusive
    }

    @ObservationIgnored private var pendingActivationCompleted = false

    @ObservationIgnored private var activationsInFlight = 0

    @ObservationIgnored private let oslog: OSLog

    init(
        bundleID: String,
        displayName: String,
        status: Status = .unknown,
        identityProbe: IdentityProbe? = nil,
        submitter: SystemExtensionSubmitting = RealSystemExtensionSubmitter(),
        deactivationBudget: Duration = .seconds(60)
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.oslog = OSLog(
            subsystem: "com.remrearas.Phantom-WG-MacOS",
            category: "gate.\(displayName)"
        )
        self.status = status
        self.identityProbe = identityProbe
        self.submitter = submitter
        self.deactivationBudget = deactivationBudget
        super.init()
    }

    private func log(_ message: String) {
        os_log("%{public}@", log: oslog, type: .default, message)
    }

    // MARK: - Public Surface

    func settle() async {
        guard let identityProbe else {
            log("settle: no probe injected → activate()")
            activate()
            return
        }
        guard !isSettling else { return }
        isSettling = true
        defer { isSettling = false }

        for attempt in 1...Self.settleAttempts {
            if let identity = await identityProbe() {
                if identity == ExtensionIdentity.current {
                    log("settle: identity match (\(identity)) — activation skipped")
                    status = .activated
                } else {
                    log("settle: identity mismatch — installed \(identity), expected \(ExtensionIdentity.current) → activate()")
                    activate()
                }
                return
            }

            let verdict = await propertiesVerdict()
            switch verdict {
            case .noLive:
                log("settle: probe silent + no live entry → activate()")
                activate()
                return
            case .awaiting:
                log("settle: probe silent + awaiting/disabled → .needsApproval")
                status = .needsApproval
                return
            case .enabled, .inconclusive:
                log("settle: probe silent, properties \(verdict) — attempt \(attempt)/\(Self.settleAttempts)")
                if attempt < Self.settleAttempts {
                    try? await Task.sleep(for: .milliseconds(600 * attempt))
                }
            }
        }

        log("settle: measurement exhausted — daemon cannot speak identity → activate()")
        activate()
    }

    private static let settleAttempts = 3

    private func propertiesVerdict() async -> PropsVerdict {
        await withCheckedContinuation { (continuation: CheckedContinuation<PropsVerdict, Never>) in
            settleContinuation = continuation
            let request = OSSystemExtensionRequest.propertiesRequest(
                forExtensionWithIdentifier: bundleID,
                queue: .main
            )
            settlePropsRequest = request
            request.delegate = self
            submitter.submit(request)
        }
    }

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
        submitter.submit(request)
    }

    func refresh() {
        log("refresh() submitted (status=\(status))")
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: bundleID,
            queue: .main
        )
        request.delegate = self
        submitter.submit(request)
    }

    enum ExtensionGateError: Error, LocalizedError {
        case deactivationAlreadyInFlight
        case deactivationNotAnswered

        var errorDescription: String? {
            let loc = LocalizationManager.shared
            switch self {
            case .deactivationAlreadyInFlight:
                return loc.t("error_uninstall_already_running")
            case .deactivationNotAnswered:
                return loc.t("error_uninstall_not_approved")
            }
        }
    }

    @ObservationIgnored private let deactivationBudget: Duration

    func deactivate() async throws {
        log("deactivate() requested (status=\(status))")
        if deactivationContinuation != nil {
            log("deactivate() refused — one is already in flight")
            throw ExtensionGateError.deactivationAlreadyInFlight
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.deactivationContinuation = continuation
            let request = OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: bundleID,
                queue: .main
            )
            self.deactivationRequest = request
            request.delegate = self
            submitter.submit(request)
            let budget = self.deactivationBudget
            self.deactivationDeadline = Task { @MainActor [weak self] in
                try? await Task.sleep(for: budget)
                guard !Task.isCancelled, let self else { return }
                self.log("deactivate() gave up waiting on the approval prompt"
                         + " — the flow gets its answer back and the refresh latch comes down with it")
                self.abandonedDeactivations.insert(ObjectIdentifier(request))
                self.resumeDeactivation(request, with: .failure(ExtensionGateError.deactivationNotAnswered))
            }
        }
    }

    private func isOurDeactivation(_ request: OSSystemExtensionRequest) -> Bool {
        request === deactivationRequest || abandonedDeactivations.contains(ObjectIdentifier(request))
    }

    private func resumeDeactivation(_ request: OSSystemExtensionRequest, with result: Result<Void, Error>) {
        guard request === deactivationRequest else { return }
        deactivationDeadline?.cancel()
        deactivationDeadline = nil
        guard let continuation = deactivationContinuation else { return }
        deactivationContinuation = nil
        deactivationRequest = nil
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
            if request === settlePropsRequest {
                settlePropsRequest = nil
                let live = properties.filter { !$0.isUninstalling }
                let verdict: PropsVerdict
                if let liveProp = pickLive(from: live) {
                    verdict = (liveProp.isAwaitingUserApproval || !liveProp.isEnabled)
                        ? .awaiting : .enabled
                } else {
                    verdict = .noLive
                }
                log("foundProperties (settle) total=\(properties.count) live=\(live.count) → \(verdict)")
                settleContinuation?.resume(returning: verdict)
                settleContinuation = nil
                return
            }

            let live = properties.filter { !$0.isUninstalling }
            log("foundProperties total=\(properties.count) live=\(live.count) pending=\(pendingActivationCompleted) status=\(status)")
            let pending = pendingActivationCompleted
            pendingActivationCompleted = false

            guard let liveProp = pickLive(from: live) else {
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
                guard activationsInFlight == 0 else {
                    log("→ live.isEnabled=true, activation in flight → holding \(status)")
                    return
                }
                log("→ live.isEnabled=true → .activated")
                status = .activated
            } else {
                log("→ live.isEnabled=false → .needsApproval (toggle off)")
                status = .needsApproval
            }
        }
    }

    private func pickLive(from live: [OSSystemExtensionProperties]) -> OSSystemExtensionProperties? {
        if let enabled = live.first(where: { $0.isEnabled }) {
            return enabled
        }
        if let awaiting = live.first(where: { $0.isAwaitingUserApproval }) {
            return awaiting
        }
        return live.first
    }

    /// @witness ExtensionGate.approvalForARemovalDoesNotPaint
    /// @witness ExtensionGate.lateAnswerIsStillARemoval
    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            guard !isOurDeactivation(request) else {
                log("requestNeedsUserApproval on the DEACTIVATION — waiting on the user, gate state left alone")
                return
            }
            log("requestNeedsUserApproval → .needsApproval")
            status = .needsApproval
        }
    }

    /// @witness ExtensionGate.aRetryIsNotAnsweredByTheRemovalItReplaced
    /// @witness ExtensionGate.lateAnswerIsStillARemoval
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            log("didFinishWithResult: \(result.rawValue) (deactivating=\(isOurDeactivation(request)))")
            if isOurDeactivation(request) {
                abandonedDeactivations.remove(ObjectIdentifier(request))
                if result == .willCompleteAfterReboot {
                    log("deactivation will complete after reboot — the provider may keep running until then")
                }
                status = .notInstalled
                resumeDeactivation(request, with: .success(()))
                return
            }
            activationsInFlight = max(0, activationsInFlight - 1)
            switch result {
            case .completed:
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
            if request === settlePropsRequest {
                settlePropsRequest = nil
                settleContinuation?.resume(returning: .inconclusive)
                settleContinuation = nil
                return
            }
            if isOurDeactivation(request) {
                abandonedDeactivations.remove(ObjectIdentifier(request))
                resumeDeactivation(request, with: .failure(error))
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
