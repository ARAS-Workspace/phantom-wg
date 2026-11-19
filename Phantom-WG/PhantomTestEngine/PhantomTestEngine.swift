// Test Engine: Runner and Context
//
// The iOS port of the macOS PhantomTestEngine. Two things live here.
//
// `TestContext` is the production object graph a workflow is handed — the
// app's own tunnels manager, on whatever system this build runs on: the
// simulated Network Extension on a simulator, the system one on a device.
// A workflow fabricates a surface only where it says so; everything else
// is the shipping object.
//
// `PhantomTestEngine` is the runner: it drives the catalogue in order,
// emits the transcript as typed lines, and answers two ways of ending
// early — `stop()` cancels the task, `requestAbort(_:)` lets a workflow
// declare the environment unfit so the rest of the catalogue is not run
// against it.
//
// The live gate: a family that drives real sessions declares
// `requiresLiveTunnels`, and it runs only when `Test-Ghost` and
// `Test-WireGuard` are listed and both run on the real Network Extension
// (their provider is the system's `NETunnelProviderManager` and their
// protocol names this app's tunnel extension). Otherwise each of its steps
// is skipped with the gate's reading; on a simulator the gate stays shut.
//
// Every run writes its transcript to `Library/Caches/PhantomTestEngine/
// last-run.txt` when it ends, and the transcript's first line says which
// workflows the run took. Launched with `-PhantomTestEngineAutorun YES`,
// the app runs the catalogue once on its own as soon as the tunnel list
// is up, so a run can be started and read without the screen. With
// `-PhantomTestEngineWorkflows` beside it, naming families by their short
// names with commas between them (`Sanity,TunnelList`), that run takes
// those workflows alone, in catalogue order; a name that is no family's
// aborts the run before any workflow. The screen's Run takes the whole
// catalogue.

#if DEBUG
import Foundation
import NetworkExtension

enum OutputKind { case header, rule, step, info, ok, warn, error, skip, result }

struct OutputLine: Identifiable {
    let id = UUID()
    let text: String
    let kind: OutputKind
}

@MainActor
struct TestContext {
    let tunnels: TunnelsManager

    static let ghostName = "Test-Ghost"
    static let wireGuardName = "Test-WireGuard"
    /// The provider bundle `NETunnelProviderProtocol(tunnelConfig:)` writes.
    static let tunnelExtensionBundle = "com.artek.Phantom-WG.PhantomTunnel"

    func tunnel(named name: String) -> TunnelContainer? {
        tunnels.tunnels.first { $0.name == name }
    }

    /// Whether `name` is listed on the real Network Extension: its provider
    /// is the system's `NETunnelProviderManager` and its protocol names this
    /// app's tunnel extension.
    func runsOnTheRealExtension(_ name: String) -> Bool {
        guard let row = tunnel(named: name),
              let manager = row.tunnelProvider as? NETunnelProviderManager,
              let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return proto.providerBundleIdentifier == Self.tunnelExtensionBundle
    }

    /// Why the live families cannot run here, or `nil` when the gate opens.
    var liveGateRefusal: String? {
        let names = [Self.ghostName, Self.wireGuardName]
        let missing = names.filter { tunnel(named: $0) == nil }
        if !missing.isEmpty {
            return "live gate: \(missing.joined(separator: " and ")) not listed"
        }
        let elsewhere = names.filter { !runsOnTheRealExtension($0) }
        if !elsewhere.isEmpty {
            return "live gate: \(elsewhere.joined(separator: " and ")) not on the real Network Extension"
        }
        return nil
    }
}

@Observable
@MainActor
final class PhantomTestEngine {

    static let shared = PhantomTestEngine()
    private init() {}

    private(set) var lines: [OutputLine] = []
    private(set) var isRunning = false

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var autorunDone = false

    private(set) var abortReason: String?

    func requestAbort(_ reason: String) {
        guard !Task.isCancelled, abortReason == nil else { return }
        abortReason = reason
        emit("      suite abort requested: \(reason)", .error)
    }

    func reset() { lines = [] }
    func emit(_ text: String, _ kind: OutputKind) { lines.append(OutputLine(text: text, kind: kind)) }

    var plainText: String { lines.map(\.text).joined(separator: "\n") }

    /// Runs `workflows` in the order given. A run asked for by names that
    /// are no family's (`unknown`) is aborted before its first workflow.
    func start(_ workflows: [TestWorkflow], _ ctx: TestContext, unknown: [String] = []) {
        guard !isRunning else { return }
        isRunning = true
        abortReason = unknown.isEmpty ? nil : "no workflow named \(unknown.joined(separator: ", "))"
        reset()
        runTask = Task { [weak self] in
            await self?.run(workflows, ctx)
        }
    }

    func stop() { runTask?.cancel() }

    // MARK: - Autorun

    static let autorunArgument = "PhantomTestEngineAutorun"
    static let workflowsArgument = "PhantomTestEngineWorkflows"

    /// Starts a run once per launch when the app was launched with
    /// `-PhantomTestEngineAutorun YES`; otherwise does nothing. The run
    /// takes the whole catalogue, or the families
    /// `-PhantomTestEngineWorkflows` names, with commas between them.
    func autorunIfRequested(_ ctx: TestContext) {
        guard !autorunDone, UserDefaults.standard.bool(forKey: Self.autorunArgument) else { return }
        autorunDone = true
        let names = (UserDefaults.standard.string(forKey: Self.workflowsArgument) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else {
            start(TestCatalog.workflows, ctx)
            return
        }
        let asked = TestCatalog.selection(names)
        start(asked.workflows, ctx, unknown: asked.unknown)
    }

    // MARK: - Transcript File

    static var transcriptURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhantomTestEngine", isDirectory: true)
            .appendingPathComponent("last-run.txt")
    }

    private func writeTranscript() {
        let url = Self.transcriptURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (plainText + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            emit("transcript not written to \(url.path): \(error.localizedDescription)", .warn)
        }
    }

    // MARK: - Run

    private func run(_ workflows: [TestWorkflow], _ ctx: TestContext) async {
        defer {
            writeTranscript()
            isRunning = false
            runTask = nil
        }
        var families: [String] = []
        for family in workflows.map(\.family) where !families.contains(family) { families.append(family) }
        let catalogue = TestCatalog.workflows.count
        let taken = workflows.count == catalogue
            ? "all \(catalogue) workflows"
            : "\(families.isEmpty ? "none" : families.joined(separator: ", ")) (\(workflows.count) of \(catalogue) workflows)"
        emit("run: \(taken)", .info)
        for workflow in workflows {
            if Task.isCancelled { break }
            if abortReason != nil { break }
            emit("", .info)
            emit("▸ \(workflow.displayName)", .header)
            emit(String(repeating: "─", count: 44), .rule)
            workflow._bind(ctx, self)
            await workflow._run()
        }
        emit("", .info)
        if Task.isCancelled {
            emit("— stopped —", .result)
        } else if let abortReason {
            emit("— aborted: \(abortReason) —", .result)
        } else {
            emit("— done —", .result)
        }
    }
}
#endif
