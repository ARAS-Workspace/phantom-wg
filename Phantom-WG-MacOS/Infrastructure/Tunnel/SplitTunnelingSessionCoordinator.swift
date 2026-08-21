import Foundation
import Observation
import os.log

@Observable
@MainActor
final class SplitTunnelingSessionCoordinator {

    enum State: Equatable {
        case stopped
        case starting
        case running
        case stopping

        var isUserVisiblyActive: Bool {
            switch self {
            case .running, .starting: return true
            case .stopped, .stopping: return false
            }
        }
    }

    private(set) var state: State = .stopped

    @ObservationIgnored private var inFlight: Task<Void, Never>?

    @ObservationIgnored private var chainGeneration = 0

    private(set) var queuedLinks = 0

    private(set) var maxChainDepth = 0

    @ObservationIgnored private var chainedStartError: Error?

    @ObservationIgnored private let chainCeiling: Duration

    private static func waitForPredecessor(
        _ predecessor: Task<Void, Never>,
        upTo ceiling: Duration
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resume = SingleResume(continuation)
            Task {
                await predecessor.value
                resume.finish(true)
            }
            Task {
                try? await Task.sleep(for: ceiling)
                resume.finish(false)
            }
        }
    }

    private func serialized(_ operation: @MainActor @escaping () async -> Void) async {
        let predecessor = inFlight
        let ceiling = chainCeiling
        let task = Task { @MainActor in
            if let predecessor {
                self.queuedLinks += 1
                self.maxChainDepth = max(self.maxChainDepth, self.queuedLinks + 1)
                defer { self.queuedLinks -= 1 }
                let landed = await Self.waitForPredecessor(predecessor, upTo: ceiling)
                if !landed {
                    self.log("chain: predecessor outlived its ceiling — proceeding anyway")
                }
            }
            await operation()
        }
        chainGeneration += 1
        let generation = chainGeneration
        inFlight = task
        await task.value
        if chainGeneration == generation { inFlight = nil }
    }

    @ObservationIgnored private let split: SplitTunnelProviderManager
    @ObservationIgnored private let dns: DNSProxyProviderManager
    @ObservationIgnored private let dnsDaemonClient: DNSProxyDaemonClient
    @ObservationIgnored private let splitDaemonClient: SplitTunnelDaemonClient
    @ObservationIgnored private let oslog = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS",
        category: "session-coordinator"
    )

    init(
        split: SplitTunnelProviderManager,
        dns: DNSProxyProviderManager,
        dnsDaemonClient: DNSProxyDaemonClient,
        splitDaemonClient: SplitTunnelDaemonClient,
        state: State = .stopped,
        chainCeiling: Duration = .seconds(60)
    ) {
        self.chainCeiling = chainCeiling
        self.split = split
        self.dns = dns
        self.dnsDaemonClient = dnsDaemonClient
        self.splitDaemonClient = splitDaemonClient
        self.state = state
    }

    // MARK: - Boot Reconcile

    @discardableResult
    func boot(freshConfig: @MainActor @escaping () -> SplitTunnelingConfiguration) async -> ReconfigureOutcome {
        var outcome = ReconfigureOutcome.notRunning
        let snapshot = freshConfig()
        await serialized { [weak self] in
            outcome = await self?.performBoot(booted: snapshot, freshConfig: freshConfig) ?? .notRunning
        }
        return outcome
    }

    private func performBoot(
        booted: SplitTunnelingConfiguration,
        freshConfig: @MainActor @escaping () -> SplitTunnelingConfiguration
    ) async -> ReconfigureOutcome {
        log("boot: start (persisted intent at entry isEnabled=\(booted.isEnabled), may be superseded after loads)")
        await split.load()
        await dns.load()
        let config = freshConfig()
        let splitStatus = split.sessionStatus
        log("boot: split.sessionStatus=\(splitStatus)")

        switch splitStatus {
        case .connected, .connecting:
            log("boot: SplitTunnel session already live → adopting .running")
            let splitPush = await splitDaemonClient.applyConfig(config)
            let dnsRealign = await dnsDaemonClient.applyConfig(config)
            log("boot: realign push → SplitTunnel \(splitPush.label), DNSProxy \(dnsRealign.label)")

            do {
                try await split.persistConfiguration(config)
                log("boot: SplitTunnel bootstrap blob realigned")
            } catch {
                log("boot: SplitTunnel bootstrap blob NOT realigned — \(error.localizedDescription)")
            }
            state = .running
            return .pushed(split: splitPush, dns: dnsRealign)
        case .disconnected, .disconnecting, .invalid:
            if config.isEnabled {
                log("boot: persisted intent ON, no live session → start()")
                try? await performStart(with: config)
            } else {
                log("boot: persisted intent OFF → state = .stopped")
                state = .stopped
            }
            return .notRunning
        }
    }

    // MARK: - Lifecycle

    func start(with config: SplitTunnelingConfiguration) async throws {
        chainedStartError = nil
        await serialized { [weak self] in
            guard let self else { return }
            do { try await self.performStart(with: config) } catch { self.chainedStartError = error }
        }
        if let error = chainedStartError {
            chainedStartError = nil
            throw error
        }
    }

    private func performStart(with config: SplitTunnelingConfiguration) async throws {
        switch state {
        case .running, .starting:
            log("start: already \(state) — no-op")
            return
        case .stopped, .stopping:
            break
        }
        log("start: enabling extensions (apps=\(config.apps.count), iface=\(config.interfaceSelection))")
        state = .starting
        do {
            try await dns.enable(with: config)
            log("start: DNSProxy registered")
            try await split.enable(with: config)
            log("start: SplitTunnel registered + tunnel started")
            state = .running
            log("start: state = .running")
        } catch {
            log("start: failed — \(error.localizedDescription); rolling back")
            state = .stopping
            var rolled: [String] = []
            do {
                try await split.disable()
                rolled.append("SplitTunnel down")
            } catch {
                rolled.append("SplitTunnel STILL UP (\(error.localizedDescription))")
            }
            do {
                try await dns.disable()
                rolled.append("DNSProxy down")
            } catch {
                rolled.append("DNSProxy STILL REGISTERED (\(error.localizedDescription))")
            }
            state = .stopped
            log("start: rollback → \(rolled.joined(separator: ", ")); state = .stopped")
            throw error
        }
    }

    @discardableResult
    func stop() async -> StopOutcome {
        var outcome = StopOutcome.alreadyStopped
        await serialized { [weak self] in
            outcome = await self?.performStop() ?? .alreadyStopped
        }
        return outcome
    }

    private func performStop() async -> StopOutcome {
        switch state {
        case .stopped, .stopping:
            log("stop: already \(state) — no-op")
            return .alreadyStopped
        case .running, .starting:
            break
        }
        log("stop: disabling extensions")
        state = .stopping
        var residue: [String] = []
        do {
            try await split.disable()
            log("stop: SplitTunnel disabled")
        } catch {
            residue.append("SplitTunnel")
            log("stop: SplitTunnel STILL REGISTERED — \(error.localizedDescription)")
        }
        do {
            try await dns.disable()
            log("stop: DNSProxy disabled")
        } catch {
            residue.append("DNSProxy")
            log("stop: DNSProxy STILL REGISTERED — \(error.localizedDescription)")
        }
        state = .stopped
        log("stop: state = .stopped")
        return residue.isEmpty ? .landed : .residue(residue)
    }

    // MARK: - Uninstall

    func purgeForUninstall() async {
        await serialized { [weak self] in
            guard let self else { return }
            _ = await self.performStop()
            await self.split.remove()
            await self.dns.remove()
            self.log("purgeForUninstall: proxy preference entry removal requested (best-effort)")
        }
    }

    // MARK: - Outcomes

    enum StopOutcome: Equatable {
        case landed
        case alreadyStopped
        case residue([String])
    }

    enum ReconfigureOutcome: Equatable {
        case notRunning
        case pushed(split: ProxyConfigDaemonClient.Push, dns: ProxyConfigDaemonClient.Push)

        var bothLanded: Bool {
            if case .pushed(let split, let dns) = self { return split == .done && dns == .done }
            return false
        }
    }

    // MARK: - Reconfigure

    /// @witness SplitControlPlane
    /// @adr 0004
    func reconfigure(with config: SplitTunnelingConfiguration) async -> ReconfigureOutcome {
        var outcome = ReconfigureOutcome.notRunning
        await serialized { [weak self] in
            outcome = await self?.performReconfigure(with: config) ?? .notRunning
        }
        return outcome
    }

    private func performReconfigure(with config: SplitTunnelingConfiguration) async -> ReconfigureOutcome {
        guard state == .running else {
            log("reconfigure: state=\(state) → no push (config persisted, applied on next start)")
            return .notRunning
        }
        log("reconfigure: XPC applyConfig → SplitTunnel")
        let splitPush = await splitDaemonClient.applyConfig(config)
        log("reconfigure: SplitTunnel applyConfig \(splitPush.label)")

        log("reconfigure: XPC applyConfig → DNSProxy")
        let dnsPush = await dnsDaemonClient.applyConfig(config)
        log("reconfigure: DNSProxy applyConfig \(dnsPush.label)")

        var persisted: [String] = []
        do {
            try await split.persistConfiguration(config)
            persisted.append("SplitTunnel ok")
        } catch {
            persisted.append("SplitTunnel FAILED (\(error.localizedDescription))")
        }
        do {
            try await dns.enable(with: config)
            persisted.append("DNSProxy ok")
        } catch {
            persisted.append("DNSProxy FAILED (\(error.localizedDescription))")
        }
        log("reconfigure: bootstrap blobs → \(persisted.joined(separator: ", "))")
        return .pushed(split: splitPush, dns: dnsPush)
    }

    // MARK: - Logging

    private func log(_ message: String) {
        os_log("%{public}@", log: oslog, type: .default, message)
    }
}
