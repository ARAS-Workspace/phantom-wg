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
// Test Engine: Vault Client That Can Be Made To Fail
//
// A `TunnelVaultClient` SUBCLASS, which is the whole point: `.real` reaches
// the shipping implementation and therefore the actual daemon. A workflow
// injects a fault only where it is measuring one, and everything it does
// not name stays production.
//
// Read, readAll, store and delete each take an answer. `ping` is
// deliberately NOT faked — it is not overridden, so every call reaches the
// real daemon whatever the other surfaces are set to:
//
//   .real                     call through to the real client
//   .answers(verdict)         return that verdict without a round trip
//   .answersAfter(s, verdict) return it after sleeping, so a caller's own
//                             deadline is the thing under test
//
// `readAnswers` overrides per id, so one payload can be made unreadable
// while its neighbours answer normally. `storeAnswersByName` and
// `deleteAnswersByName` do the same for writes, keyed by the tunnel's name,
// for a payload whose id is minted inside the batch under test; a delete
// finds its name among the configurations handed to `store`.
//
// `goesDarkAfterStores` and `goesDarkAfterDeletes` turn the whole vault
// dark once that many writes have answered done: from then on read,
// readAll, store and delete all answer unreachable at once.
//
// It also RECORDS: which ids were read, stored and deleted, and the
// configurations handed to `store`. Several steps assert on what was asked
// for rather than on what came back. `held` is the other reading: the
// payloads a vault answering this way would hold, a store or a delete
// counted only where it answered done.

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
    var storeAnswersByName: [String: Answer<Write>] = [:]
    var deleteAnswersByName: [String: Answer<Write>] = [:]
    var goesDarkAfterStores: Int?
    var goesDarkAfterDeletes: Int?

    // MARK: - Observed state

    private(set) var readIds: [UUID] = []
    private(set) var deletedIds: [UUID] = []
    private(set) var storedIds: [UUID] = []

    private(set) var storedConfigs: [TunnelConfig] = []
    private(set) var held: [UUID: TunnelConfig] = [:]
    private(set) var isDark = false
    private var storesDone = 0
    private var deletesDone = 0

    // MARK: - RPCs

    override func read(id: UUID) async -> Read {
        readIds.append(id)
        if isDark { return .unreachable }
        switch readAnswers[id] ?? readAnswer {
        case .real: return await super.read(id: id)
        case .answers(let verdict): return verdict
        case .answersAfter(let seconds, let verdict): return await Self.after(seconds, verdict)
        }
    }

    override func readAll() async -> ReadAll {
        if isDark { return .unreachable }
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
        if isDark { return .unreachable }
        let verdict: Write
        switch storeAnswersByName[config.name] ?? storeAnswer {
        case .real: verdict = await super.store(config)
        case .answers(let answer): verdict = answer
        case .answersAfter(let seconds, let answer): verdict = await Self.after(seconds, answer)
        }
        if verdict == .done {
            held[config.id] = config
            storesDone += 1
            if let limit = goesDarkAfterStores, storesDone >= limit { isDark = true }
        }
        return verdict
    }

    @discardableResult
    override func delete(id: UUID) async -> Write {
        deletedIds.append(id)
        if isDark { return .unreachable }
        let name = storedConfigs.last { $0.id == id }?.name
        let verdict: Write
        switch name.flatMap({ deleteAnswersByName[$0] }) ?? deleteAnswer {
        case .real: verdict = await super.delete(id: id)
        case .answers(let answer): verdict = answer
        case .answersAfter(let seconds, let answer): verdict = await Self.after(seconds, answer)
        }
        if verdict == .done {
            held[id] = nil
            deletesDone += 1
            if let limit = goesDarkAfterDeletes, deletesDone >= limit { isDark = true }
        }
        return verdict
    }

    private static func after<Verdict>(_ seconds: Double, _ verdict: Verdict) async -> Verdict {
        try? await Task.sleep(for: .seconds(seconds))
        return verdict
    }
}
#endif
