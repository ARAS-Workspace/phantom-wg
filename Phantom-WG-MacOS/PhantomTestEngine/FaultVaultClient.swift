#if DEBUG
import Foundation

@MainActor
final class FaultVaultClient: TunnelVaultClient {

    // MARK: - Injectable answers

    enum Answer<Verdict> {
        case real
        case answers(Verdict)
        case answersAfter(seconds: Double, Verdict)
    }

    var readAnswer: Answer<Read> = .real
    var readAnswers: [UUID: Answer<Read>] = [:]
    var readAllAnswer: Answer<ReadAll> = .real
    var storeAnswer: Answer<Write> = .real
    var deleteAnswer: Answer<Write> = .real

    // MARK: - Observed state

    private(set) var readIds: [UUID] = []
    private(set) var deletedIds: [UUID] = []
    private(set) var storedIds: [UUID] = []

    private(set) var storedConfigs: [TunnelConfig] = []

    // MARK: - RPCs

    override func read(id: UUID) async -> Read {
        readIds.append(id)
        switch readAnswers[id] ?? readAnswer {
        case .real: return await super.read(id: id)
        case .answers(let verdict): return verdict
        case .answersAfter(let seconds, let verdict): return await Self.after(seconds, verdict)
        }
    }

    override func readAll() async -> ReadAll {
        switch readAllAnswer {
        case .real: return await super.readAll()
        case .answers(let verdict): return verdict
        case .answersAfter(let seconds, let verdict): return await Self.after(seconds, verdict)
        }
    }

    @discardableResult
    override func store(_ config: TunnelConfig) async -> Write {
        storedIds.append(config.id)
        storedConfigs.append(config)
        switch storeAnswer {
        case .real: return await super.store(config)
        case .answers(let verdict): return verdict
        case .answersAfter(let seconds, let verdict): return await Self.after(seconds, verdict)
        }
    }

    @discardableResult
    override func delete(id: UUID) async -> Write {
        deletedIds.append(id)
        switch deleteAnswer {
        case .real: return await super.delete(id: id)
        case .answers(let verdict): return verdict
        case .answersAfter(let seconds, let verdict): return await Self.after(seconds, verdict)
        }
    }

    private static func after<Verdict>(_ seconds: Double, _ verdict: Verdict) async -> Verdict {
        try? await Task.sleep(for: .seconds(seconds))
        return verdict
    }
}
#endif
