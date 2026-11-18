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
// Every run writes its transcript to `Library/Caches/PhantomTestEngine/
// last-run.txt` when it ends. Launched with `-PhantomTestEngineAutorun
// YES`, the app runs the catalogue once on its own as soon as the tunnel
// list is up, so a run can be started and read without the screen.

#if DEBUG
import Foundation

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

    func tunnel(named name: String) -> TunnelContainer? {
        tunnels.tunnels.first { $0.name == name }
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

    func start(_ workflows: [TestWorkflow], _ ctx: TestContext) {
        guard !isRunning else { return }
        isRunning = true
        abortReason = nil
        reset()
        runTask = Task { [weak self] in
            await self?.run(workflows, ctx)
        }
    }

    func stop() { runTask?.cancel() }

    // MARK: - Autorun

    static let autorunArgument = "PhantomTestEngineAutorun"

    /// Starts the catalogue once per launch when the app was launched
    /// with `-PhantomTestEngineAutorun YES`; otherwise does nothing.
    func autorunIfRequested(_ ctx: TestContext) {
        guard !autorunDone, UserDefaults.standard.bool(forKey: Self.autorunArgument) else { return }
        autorunDone = true
        start(TestCatalog.workflows, ctx)
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
        for (index, workflow) in workflows.enumerated() {
            if Task.isCancelled { break }
            if abortReason != nil { break }
            if index > 0 { emit("", .info) }
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
