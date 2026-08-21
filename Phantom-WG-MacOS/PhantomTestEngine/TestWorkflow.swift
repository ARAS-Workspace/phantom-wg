// ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
// ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
// ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
// ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
// ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
// ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
//
// Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
// Licensed under AGPL-3.0 - see LICENSE file for details
// WireGuard® is a registered trademark of Jason A. Donenfeld.
//
// Test Engine: Workflow Base
//
// What every workflow inherits: the context accessors, the vocabulary a
// step speaks in, and the arrangements a step should never re-implement.
//
// The vocabulary is four verbs, and the distinction between them is the
// suite's honesty:
//
//   check(_:_:)  a claim that can go red — the message states what is
//                true when it passes
//   fail(_:)     the step could not be arranged, or the claim did not hold
//   skip(_:)     the environment cannot answer this question, and the run
//                says WHICH reading refused rather than going quiet
//   log(_:_:)    an observation carrying no verdict
//
// The waiting helpers exist because reading a system value once is the
// most common way a step measures its own sampling rate rather than the
// product: `awaitStatus`, `settle(within:until:)` and `race` all bound the
// wait and report whether it landed.
//
// `onTeardown(_:_:)` registers cleanup that runs whether the step passed,
// failed or was never reached — a workflow that plants something owes its
// removal to the machine it borrowed.
//
// `_bind` and `_run` are the runner's entry points and belong to it.

#if DEBUG
import Foundation

enum ProviderReply: Equatable {
    case data(Data)
    case empty
    case unanswered

    var label: String {
        switch self {
        case .data(let d): return "data(\(d.count) bytes)"
        case .empty: return "empty"
        case .unanswered: return "unanswered"
        }
    }
}

struct WorkflowStep {
    let title: String
    let body: @MainActor () async -> Void
    init(_ title: String, _ body: @escaping @MainActor () async -> Void) {
        self.title = title
        self.body = body
    }
}

@MainActor
class TestWorkflow {
    private var context: TestContext!
    private weak var engine: PhantomTestEngine?
    private var stepFailed = false
    private var stepSkipReason: String?

    // MARK: - Subclass surface (override these)

    var displayName: String { "" }
    var steps: [WorkflowStep] { [] }

    // MARK: - Everything the app exposes to the user (no plumbing)

    var tunnels: TunnelsManager { context.tunnels }
    var vault: TunnelVaultClient { context.vault }
    var vaultSession: TunnelVaultSession { context.vaultSession }
    var gate: ExtensionGateCoordinator { context.gate }
    var split: SplitTunnelingSessionCoordinator { context.split }
    var splitStore: SplitTunnelingStore { context.splitStore }
    var splitManager: SplitTunnelProviderManager { context.splitManager }
    var dnsManager: DNSProxyProviderManager { context.dnsManager }
    var dnsClient: DNSProxyDaemonClient { context.dnsClient }
    var splitClient: SplitTunnelDaemonClient { context.splitClient }
    var interfaceResolver: PhysicalInterfaceResolver { context.interfaceResolver }
    func tunnel(named name: String) -> TunnelContainer? { context.tunnel(named: name) }

    let vaultRaw = TestVaultRawClient()

    var systemProviders: TunnelProviderFactory { RealTunnelProviderFactory() }

    var activationBudget: Double { tunnels.activationCeiling }

    func abortRun(_ reason: String) {
        engine?.requestAbort(reason)
    }

    // MARK: - Step helpers (English, indented under the current step)

    func log(_ text: String, _ level: OutputKind = .info) {
        engine?.emit("      \(text)", level)
    }
    func fail(_ message: String? = nil) {
        if Task.isCancelled {
            if let message { log("\(message) — unproven, run stopped", .skip) }
            return
        }
        stepFailed = true
        if let message { log(message, .error) }
    }
    @discardableResult
    func check(_ condition: Bool, _ message: String) -> Bool {
        if Task.isCancelled {
            log("\(message) — unproven, run stopped", .skip)
            return condition
        }
        log(message, condition ? .ok : .error)
        if !condition { stepFailed = true }
        return condition
    }
    func skip(_ reason: String) {
        stepSkipReason = reason
    }

    // MARK: - Live-surface helpers (timeout-guarded, English)

    @discardableResult
    func awaitStatus(_ tunnel: TunnelContainer, is target: TunnelStatus, within seconds: Double) async -> Bool {
        let start = Date()
        var last = tunnel.status
        while Date().timeIntervalSince(start) < seconds {
            if Task.isCancelled { return false }
            if tunnel.status != last {
                log("status: \(last) → \(tunnel.status) (t=\(Self.elapsed(start)))")
                last = tunnel.status
            }
            if tunnel.status == target { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if tunnel.status == target { return true }
        log("status stayed \(tunnel.status) — no \(target) within \(Int(seconds))s", .warn)
        return false
    }

    func settle(within seconds: Double, until condition: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if condition() { return true }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    func providerMessage(_ tunnel: TunnelContainer, _ bytes: [UInt8], timeout: Double = 5) async -> ProviderReply {
        await withCheckedContinuation { continuation in
            let resume = SingleResume(continuation)
            do {
                try tunnel.tunnelProvider.sendProviderMessage(Data(bytes)) { data in
                    resume.finish(data.map(ProviderReply.data) ?? .empty)
                }
            } catch {
                resume.finish(.unanswered)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                resume.finish(.unanswered)
            }
        }
    }

    func race<T: Sendable>(_ seconds: Double, _ operation: @escaping @MainActor () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resume = SingleResume(continuation)
            Task { @MainActor in resume.finish(await operation()) }
            Task { try? await Task.sleep(for: .seconds(seconds)); resume.finish(nil) }
        }
    }

    private static func elapsed(_ start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }

    // MARK: - Teardown (residue net)

    func onTeardown(_ label: String, _ body: @escaping @MainActor () async -> Void) {
        teardowns.append((label, body))
    }

    private var teardowns: [(label: String, body: @MainActor () async -> Void)] = []

    private static let teardownCeiling: Double = 100

    private func runTeardowns() async {
        guard !teardowns.isEmpty else { return }
        let jobs = Array(teardowns.reversed())
        teardowns.removeAll()
        engine?.emit("  • Teardown", .step)
        for job in jobs {
            let finished: Void? = await race(Self.teardownCeiling) { await job.body() }
            if finished == nil {
                engine?.emit("      \(job.label): still running past \(Int(Self.teardownCeiling))s — this run stopped waiting for it (its verdict may still print below, detached)", .warn)
            }
        }
    }

    // MARK: - Runner entry (not for subclasses)

    // swiftlint:disable:next identifier_name
    func _bind(_ context: TestContext, _ engine: PhantomTestEngine) {
        self.context = context
        self.engine = engine
    }
    // swiftlint:disable:next identifier_name
    func _run() async {
        for step in steps {
            if Task.isCancelled { break }
            if engine?.abortReason != nil { break }
            stepFailed = false
            stepSkipReason = nil
            engine?.emit("  • \(step.title)", .step)
            await step.body()
            if stepFailed {
                engine?.emit("    ✗ FAIL", .error)
                if Task.isCancelled { break }
            } else if Task.isCancelled {
                engine?.emit("    ◦ SKIP (cancelled)", .skip)
                break
            } else if let reason = stepSkipReason {
                engine?.emit("    ◦ SKIP (\(reason))", .skip)
            } else {
                engine?.emit("    ✓ PASS", .ok)
            }
        }
        await runTeardowns()
    }
}
#endif
