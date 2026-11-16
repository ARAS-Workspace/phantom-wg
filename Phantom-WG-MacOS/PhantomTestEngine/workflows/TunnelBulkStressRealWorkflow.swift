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
// Tunnel Bulk Stress (Real Stores)
//
// The second layer of Tunnel Bulk Stress: the same bulk import and bulk
// delete, driven through `TunnelBulkImport` and `TunnelBulkDelete` into the
// app's own tunnel manager, over the real stores — the live list, the
// system's entries read from a fresh `loadAllFromPreferences` and the vault
// read with `readAll`. The live manager hears the system's configuration
// changes, so each batch runs under the refreshes they raise. The
// agreement each step ends on is the first layer's `TunnelStoreReading`.
//
// The rows this workflow plants show in the user's list and in System
// Settings while it runs. Every one carries the prefix TE-Stress-R- and the
// run's tag; the teardown sweeps them through the verified sweep kit, and
// the first step sweeps any an interrupted run left behind.
//
// The readers cannot be mutated outside the app, so the second step is
// their positive control: a payload the vault holds with no entry and no
// row is read by all three readers and called a disagreement.
//
// Durations, the paint the system gives a fresh entry and the number of
// configuration change notifications are logged; they carry no verdict.
//
// Scenarios:
//
//   A — No Leftover From An Earlier Run
//       Rows, entries and payloads carrying the prefix are swept, and none
//       of the three stores holds one afterwards. A store that does not
//       answer skips the step.
//
//   B — The Store Readers See A Payload Without Its Entry
//       A payload is written to the vault alone. The vault reader finds it,
//       the list and the system's entries do not, and the agreement reads
//       false. The payload is then deleted and read back gone.
//
//   C — Five Tunnels Import Whole And Delete Whole
//       A five-entry archive is imported into the live list: all five are
//       added and the three stores agree on the same five ids, each payload
//       the configuration its entry carried. A bulk delete of the five takes
//       them all, the three stores hold none of them, and the user's own
//       tunnels are where they were: the stores read the same ids as before
//       the import.

#if DEBUG
import Foundation
import NetworkExtension

final class TunnelBulkStressRealWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Bulk Stress (Real Stores)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("No Leftover From An Earlier Run", noLeftoverFromAnEarlierRun),
            WorkflowStep("The Store Readers See A Payload Without Its Entry", theReadersSeeAPayloadWithoutItsEntry),
            WorkflowStep("Five Tunnels Import Whole And Delete Whole", fiveTunnelsImportWholeAndDeleteWhole),
        ]
    }

    @MainActor
    private final class Counter {
        var count = 0
    }

    private struct Named {
        let reading: TunnelStoreReading
        let names: [UUID: String]
    }

    private static let prefix = "TE-Stress-R-"
    private let size = 5
    private let convergence = 5.0
    private let runTag = String(UUID().uuidString.prefix(8))
    private var directory: URL?

    // MARK: - Readers

    private func read(_ match: (String) -> Bool) async -> Named? {
        var names: [UUID: String] = [:]
        let rows = tunnels.tunnels.filter { match($0.name) }
        for row in rows { names[row.id] = row.name }
        guard let providers = try? await systemProviders.loadAllFromPreferences() else { return nil }
        var entries: [UUID] = []
        for provider in providers {
            guard let identity = provider.tunnelIdentity, match(identity.name) else { continue }
            entries.append(identity.id)
            names[identity.id] = identity.name
        }
        guard case .configs(let configs) = await vault.readAll() else { return nil }
        let payloads = configs.filter { match($0.name) }
        for payload in payloads { names[payload.id] = payload.name }
        return Named(
            reading: TunnelStoreReading(rows: rows.map(\.id), entries: entries, payloads: payloads.map(\.id)),
            names: names
        )
    }

    private func settled(
        _ match: (String) -> Bool,
        until condition: (TunnelStoreReading) -> Bool
    ) async -> (reading: TunnelStoreReading?, after: Double?) {
        let started = ContinuousClock.now
        var last = await read(match)
        while true {
            if let last, condition(last.reading) {
                return (last.reading, Self.milliseconds(ContinuousClock.now - started))
            }
            if ContinuousClock.now - started > .seconds(convergence) || Task.isCancelled {
                return (last?.reading, nil)
            }
            try? await Task.sleep(for: .milliseconds(250))
            last = await read(match)
        }
    }

    private func countingConfigurationChanges<T>(_ body: () async -> T) async -> (T, Int) {
        let counter = Counter()
        let token = NotificationCenter.default.addObserver(forName: .NEVPNConfigurationChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { counter.count += 1 }
        }
        let result = await body()
        try? await Task.sleep(for: .milliseconds(500))
        NotificationCenter.default.removeObserver(token)
        return (result, counter.count)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    private static func timing(_ label: String, _ duration: Duration, count: Int) -> String {
        let total = milliseconds(duration)
        let each = total / Double(max(count, 1))
        return "\(label): \(String(format: "%.0f", total)) ms in all, \(String(format: "%.1f", each)) ms per tunnel (\(count))"
    }

    private static func after(_ milliseconds: Double?) -> String {
        milliseconds.map { "agreed \(String(format: "%.0f", $0)) ms after the batch returned" } ?? "not within the wait"
    }

    // MARK: - Step A

    private func noLeftoverFromAnEarlierRun() async {
        guard let found = await read({ $0.hasPrefix(Self.prefix) }) else {
            skip("the vault or the system list did not answer, so leftovers cannot be read")
            return
        }
        let ids = Set(found.reading.rows + found.reading.entries + found.reading.payloads)
        log("leftovers carrying \(Self.prefix): \(found.reading.line)")
        for id in ids {
            await sweepPlantedTunnel(id: id, name: found.names[id] ?? "\(Self.prefix)\(id)")
        }
        let (left, _) = await settled({ $0.hasPrefix(Self.prefix) }, until: \.isEmpty)
        check(left?.isEmpty == true,
              "none of the three stores holds a row, an entry or a payload carrying \(Self.prefix) (swept \(ids.count), now \(left?.line ?? "unreadable"))")
    }

    // MARK: - Step B

    private func theReadersSeeAPayloadWithoutItsEntry() async {
        let controlName = "\(Self.prefix)Control-\(runTag)"
        guard let config = TestConfigFactory.throwaway(name: controlName) else {
            fail("the config factory did not produce the control payload")
            return
        }
        onTeardown("control payload") { [weak self] in
            await self?.sweepPlantedTunnel(id: config.id, name: controlName)
        }
        guard await vault.store(config, attempts: 3) == .done else {
            skip("the vault did not take the control payload")
            return
        }
        guard let seen = await read({ $0 == controlName }) else {
            skip("the vault or the system list did not answer after the control was written")
            return
        }
        check(seen.reading.payloads == [config.id]
                && seen.reading.rows.isEmpty
                && seen.reading.entries.isEmpty
                && !seen.reading.agree,
              "the vault reader found the control payload, the list and the system's entries did not, and the agreement reads false (\(seen.reading.line))")

        let verdict = await verifiedDelete(config.id)
        let gone = await read({ $0 == controlName })
        check([SweepVerdict.swept, .sweptOnReread].contains(verdict) && gone?.reading.isEmpty == true,
              "the control payload was deleted and reads back gone (verdict=\(verdict), now \(gone?.reading.line ?? "unreadable"))")
    }

    // MARK: - Step C

    private func workDirectory() -> URL? {
        if let directory { return directory }
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-bulk-stress-real-\(runTag)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        onTeardown("stress folder") {
            try? FileManager.default.removeItem(at: made)
        }
        directory = made
        return made
    }

    private func fiveTunnelsImportWholeAndDeleteWhole() async {
        let names = (1...size).map { "\(Self.prefix)\(String(format: "%02d", $0))-\(runTag)" }
        var sources: [String: TunnelConfig] = [:]
        var entries: [(String, Data)] = []
        for (index, tunnelName) in names.enumerated() {
            guard let config = TestConfigFactory.throwaway(name: tunnelName, ghost: index % 2 == 1) else {
                fail("the config factory did not produce \(tunnelName)")
                return
            }
            sources[tunnelName] = config
            entries.append(("batch/\(tunnelName).conf", TunnelConfFile.data(config.asConfString())))
        }
        guard let folder = workDirectory() else {
            fail("the temporary folder could not be made")
            return
        }
        let archive = folder.appendingPathComponent("stress-real-\(size).zip")
        do {
            try ZipArchive.write(entries, to: archive)
        } catch {
            fail("the archive could not be written: \(error.localizedDescription)")
            return
        }
        onTeardown("planted stress tunnels") { [weak self] in
            guard let self else { return }
            for tunnelName in names {
                guard let config = sources[tunnelName] else { continue }
                await self.sweepPlantedTunnel(id: config.id, name: tunnelName)
            }
        }
        guard let baseline = await read({ _ in true }) else {
            skip("the vault or the system list did not answer before the import")
            return
        }
        log("before the import: \(baseline.reading.line)")
        guard await importsWhole(names, sources: sources, archive: archive) else { return }
        await deletesWhole(names, baseline: baseline.reading)
    }

    private func importsWhole(_ names: [String], sources: [String: TunnelConfig], archive: URL) async -> Bool {
        let isRun = { (name: String) in names.contains(name) }
        let started = ContinuousClock.now
        let (report, changes) = await countingConfigurationChanges {
            await TunnelBulkImport.run([archive], into: tunnels)
        }
        log(Self.timing("import", ContinuousClock.now - started, count: report.added.count))
        log("configuration change notifications during the import: \(changes)")

        check(report.added == names && report.skipped.isEmpty,
              "every entry of the \(size)-entry archive was added, in label order, and nothing was reported (added=\(report.added.count), skipped=\(report.skipped.map { "\($0.label): \($0.skip)" }))")

        let (held, after) = await settled(isRun) { $0.agree && $0.rows.count == self.size }
        check(held.map { $0.agree && $0.rows.count == size } == true,
              "the live list, the system's entries and the vault hold the same \(size) ids, each once (\(held?.line ?? "unreadable"), \(Self.after(after)))")

        if case .configs(let configs) = await vault.readAll() {
            let mismatched = names.filter { tunnelName in
                guard let source = sources[tunnelName],
                      let payload = configs.first(where: { $0.name == tunnelName }) else { return true }
                return payload.wireguard != source.wireguard || payload.wstunnel != source.wstunnel
            }
            check(mismatched.isEmpty,
                  "every payload in the vault is the configuration its entry carried, the Ghost ones with their Wstunnel part (mismatched=\(mismatched.count))")
        } else {
            fail("the vault did not answer the payload comparison")
        }

        let painted = tunnels.tunnels.filter { isRun($0.name) }.map { "\($0.status)" }
        log("rows painted after the import: \(Dictionary(grouping: painted) { $0 }.mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        return !report.added.isEmpty
    }

    private func deletesWhole(_ names: [String], baseline: TunnelStoreReading) async {
        let isRun = { (name: String) in names.contains(name) }
        let rows = TunnelListRules.ordered(tunnels.tunnels.filter { isRun($0.name) }, saved: [], id: \.id)
        let targets = TunnelBulkDelete.targets(rows, marked: Set(rows.map(\.id)))
        var progress: [Int] = []
        let started = ContinuousClock.now
        let (report, changes) = await countingConfigurationChanges {
            await TunnelBulkDelete.run(targets, in: tunnels) { progress.append($0) }
        }
        log(Self.timing("delete", ContinuousClock.now - started, count: targets.count))
        log("configuration change notifications during the delete: \(changes)")

        check(!targets.isEmpty
                && report.deleted == targets.map(\.name)
                && report.skipped.isEmpty
                && progress == Array(1...targets.count),
              "the bulk delete took every planted row in list order, skipped none and counted each once (targets=\(targets.count), deleted=\(report.deleted.count), skipped=\(report.skipped.map { "\($0.name): \($0.skip)" }), progress last=\(progress.last ?? 0))")

        let (left, after) = await settled(isRun, until: \.isEmpty)
        check(left?.isEmpty == true,
              "none of the three real stores holds a planted tunnel (\(left?.line ?? "unreadable"), \(Self.after(after).replacingOccurrences(of: "agreed", with: "emptied")))")

        let (everything, _) = await settled({ _ in true }, until: {
            Set($0.rows) == Set(baseline.rows) && Set($0.entries) == Set(baseline.entries) && Set($0.payloads) == Set(baseline.payloads)
        })
        check(everything.map {
                  Set($0.rows) == Set(baseline.rows)
                      && Set($0.entries) == Set(baseline.entries)
                      && Set($0.payloads) == Set(baseline.payloads)
              } == true,
              "the user's own tunnels are where they were: the three stores read the same ids as before the import (before \(baseline.line), now \(everything?.line ?? "unreadable"))")
    }
}
#endif
