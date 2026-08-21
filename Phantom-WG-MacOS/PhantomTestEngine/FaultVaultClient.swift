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
// Each RPC takes an answer:
//
//   .real                     call through to the real client
//   .answers(verdict)         return that verdict without a round trip
//   .answersAfter(s, verdict) return it after sleeping, so a caller's own
//                             deadline is the thing under test
//
// `readAnswers` overrides per id, so one payload can be made unreadable
// while its neighbours answer normally.
//
// It also RECORDS: which ids were read, stored and deleted, and the
// configurations handed to `store`. Several steps assert on what was asked
// for rather than on what came back.

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
