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
// A batch's duration covers the batch alone. Its notifications are counted
// from its start to 500 ms after it returns. The store readings begin the
// moment it returns, and the log names the read on which they agreed and
// how long after the batch that read finished.
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
//
//   D — Fifty Tunnels Import Whole And Delete Whole
//       C at fifty tunnels, with the same checks. A log line then sets its
//       per-tunnel durations, notifications per tunnel and the time the
//       stores took to agree and to empty beside C's.
//
//   E — A Delete And An Import That Overlap Keep Their Own Rows
//       Fifty tunnels (set A) are imported into the live list. A bulk
//       delete of all fifty starts and, without waiting for it, a bulk
//       import of a ten-entry archive (set B). The two batches share the
//       main actor and the live manager, which hears the system's changes
//       from both. The step first shows that they did overlap: set B rows
//       were arriving on the live list while the delete was still
//       counting. The delete's progress callback cannot await the vault,
//       so this reading comes from the list under test. Then the delete
//       took all of A, the import added all of B, and the three stores
//       hold exactly B's ten ids, each payload the configuration its entry
//       carried. A bulk delete of B then leaves the stores as they were
//       before A was imported. The configuration change notifications from
//       A's import to the reading of the stores are logged by when they
//       arrived, and by set where a notification names its configuration;
//       an A notification inside the overlap's window that arrived before
//       its own tunnel's delete began is counted on its own.

#if DEBUG
import Foundation
import NetworkExtension

@MainActor
private final class ChangeRecorder {
    struct Arrival {
        let at: ContinuousClock.Instant
        let name: String?
        let object: String
    }

    private(set) var arrivals: [Arrival] = []
    private var token: NSObjectProtocol?

    func start() {
        let center = NotificationCenter.default
        token = center.addObserver(forName: .NEVPNConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.arrivals.append(Arrival(
                    at: .now,
                    name: (notification.object as? NEVPNManager)?.localizedDescription,
                    object: notification.object.map { "\(type(of: $0))" } ?? "no object"
                ))
            }
        }
    }

    func stop() {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
        token = nil
    }
}

private struct OverlapTiming {
    let started: ContinuousClock.Instant
    let windowEnd: ContinuousClock.Instant
    let beganAt: [String: ContinuousClock.Instant]
}

private enum OverlapArrivals {
    static func lines(
        _ arrivals: [ChangeRecorder.Arrival],
        listedAt: ContinuousClock.Instant,
        timing: OverlapTiming,
        setA: Set<String>,
        setB: Set<String>
    ) -> [String] {
        func set(of arrival: ChangeRecorder.Arrival) -> String {
            guard let name = arrival.name else { return "unnamed \(arrival.object)" }
            if setA.contains(name) { return "A" }
            if setB.contains(name) { return "B" }
            return "other"
        }
        func tally(_ group: [ChangeRecorder.Arrival]) -> String {
            let counts = Dictionary(grouping: group, by: set(of:)).mapValues(\.count)
            guard !counts.isEmpty else { return "none" }
            return counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
        func milliseconds(_ duration: Duration) -> String {
            let parts = duration.components
            return String(format: "%.0f", Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
        }
        let importing = arrivals.filter { $0.at <= listedAt }
        let gap = arrivals.filter { $0.at > listedAt && $0.at < timing.started }
        let inside = arrivals.filter { $0.at >= timing.started && $0.at <= timing.windowEnd }
        let later = arrivals.filter { $0.at > timing.windowEnd }
        let early = inside.filter { arrival in
            guard let name = arrival.name, let began = timing.beganAt[name] else { return false }
            return arrival.at < began
        }
        let earlyAt = early.map { milliseconds($0.at - listedAt) }.joined(separator: ", ")
        return [
            "notifications while set A was imported: \(tally(importing))",
            "set A's import returned \(milliseconds(timing.started - listedAt)) ms before the overlap's window opened, notifications in that gap: \(tally(gap))",
            "notifications inside the overlap's window: \(tally(inside))",
            "set A notifications inside the window that arrived before their own tunnel's delete began: \(early.count)"
                + (early.isEmpty ? "" : ", at \(earlyAt) ms after set A's import returned"),
            "notifications after the window, until the stores were read: \(tally(later))",
        ]
    }
}

final class TunnelBulkStressRealWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Bulk Stress (Real Stores)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("No Leftover From An Earlier Run", noLeftoverFromAnEarlierRun),
            WorkflowStep("The Store Readers See A Payload Without Its Entry", theReadersSeeAPayloadWithoutItsEntry),
            WorkflowStep("Five Tunnels Import Whole And Delete Whole", fiveTunnelsImportWholeAndDeleteWhole),
            WorkflowStep("Fifty Tunnels Import Whole And Delete Whole", fiftyTunnelsImportWholeAndDeleteWhole),
            WorkflowStep("A Delete And An Import That Overlap Keep Their Own Rows", aDeleteAndAnImportThatOverlapKeepTheirOwnRows),
        ]
    }

    @MainActor
    private final class Arrivals {
        var instants: [ContinuousClock.Instant] = []
    }

    @MainActor
    private final class Samples {
        var progress: [Int] = []
        var progressAt: [ContinuousClock.Instant] = []
        var listedOfB: [Int] = []
    }

    private struct Batch {
        let label: String
        let names: [String]
        let sources: [String: TunnelConfig]
        let archive: URL
    }

    private struct Overlap {
        let deleted: TunnelBulkDelete.Report
        let deleteTook: Duration
        let imported: TunnelBulkImport.Report
        let importTook: Duration
    }

    private struct Named {
        let reading: TunnelStoreReading
        let names: [UUID: String]
    }

    private struct Settled {
        let reading: TunnelStoreReading?
        let after: Double?
        let reads: Int
    }

    private struct Watched<Result> {
        let result: Result
        let started: ContinuousClock.Instant
        let returned: ContinuousClock.Instant
        let changes: Int
        let settled: Settled

        var took: Duration { returned - started }
    }

    private struct Imported {
        let each: Double
        let changes: Int
        let agreed: Settled
    }

    private struct Deleted {
        let each: Double
        let changes: Int
        let emptied: Settled
    }

    private static let prefix = "TE-Stress-R-"
    private let smallBatch = 5
    private let largeBatch = 50
    private let overlapDeleted = 50
    private let overlapImported = 10
    private var measured: [Int: (imported: Imported, deleted: Deleted)] = [:]
    private let convergence = 5.0
    private let changeWindow = Duration.milliseconds(500)
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
    ) async -> Settled {
        let started = ContinuousClock.now
        var reads = 1
        var last = await read(match)
        while true {
            if let last, condition(last.reading) {
                return Settled(reading: last.reading, after: Self.milliseconds(ContinuousClock.now - started), reads: reads)
            }
            if ContinuousClock.now - started > .seconds(convergence) || Task.isCancelled {
                return Settled(reading: last?.reading, after: nil, reads: reads)
            }
            try? await Task.sleep(for: .milliseconds(250))
            last = await read(match)
            reads += 1
        }
    }

    private func watching<Result>(
        _ batch: () async -> Result,
        settling match: (String) -> Bool,
        until condition: (TunnelStoreReading) -> Bool
    ) async -> Watched<Result> {
        let arrivals = Arrivals()
        let token = NotificationCenter.default.addObserver(forName: .NEVPNConfigurationChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { arrivals.instants.append(.now) }
        }
        let started = ContinuousClock.now
        let result = await batch()
        let returned = ContinuousClock.now
        let landed = await settled(match, until: condition)
        let windowEnd = returned + changeWindow
        if ContinuousClock.now < windowEnd {
            try? await Task.sleep(until: windowEnd)
        }
        NotificationCenter.default.removeObserver(token)
        return Watched(
            result: result,
            started: started,
            returned: returned,
            changes: arrivals.instants.filter { $0 <= windowEnd }.count,
            settled: landed
        )
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

    private static func after(_ settled: Settled, _ verb: String) -> String {
        guard let after = settled.after else { return "not \(verb) within the wait, \(settled.reads) reads" }
        return "\(verb) on read \(settled.reads), \(String(format: "%.0f", after)) ms after the batch returned"
    }

    private func notifications(_ batch: String, _ changes: Int) -> String {
        "configuration change notifications from the \(batch)'s start to \(String(format: "%.0f", Self.milliseconds(changeWindow))) ms after it returned: \(changes)"
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
        let left = await settled({ $0.hasPrefix(Self.prefix) }, until: \.isEmpty).reading
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
        await importsWholeAndDeletesWhole(count: smallBatch)
    }

    private func fiftyTunnelsImportWholeAndDeleteWhole() async {
        await importsWholeAndDeletesWhole(count: largeBatch)
        compare(largeBatch, with: smallBatch)
    }

    private func plant(_ set: String, count: Int) -> Batch? {
        let label = "\(Self.prefix)\(set)\(count)"
        let names = (1...count).map { "\(label)-\(String(format: "%03d", $0))-\(runTag)" }
        var sources: [String: TunnelConfig] = [:]
        var entries: [(String, Data)] = []
        for (index, tunnelName) in names.enumerated() {
            guard let config = TestConfigFactory.throwaway(name: tunnelName, ghost: index % 2 == 1) else {
                fail("the config factory did not produce \(tunnelName)")
                return nil
            }
            sources[tunnelName] = config
            entries.append(("batch/\(tunnelName).conf", TunnelConfFile.data(config.asConfString())))
        }
        guard let folder = workDirectory() else {
            fail("the temporary folder could not be made")
            return nil
        }
        let archive = folder.appendingPathComponent("stress-real-\(set)\(count).zip")
        do {
            try ZipArchive.write(entries, to: archive)
        } catch {
            fail("the archive could not be written: \(error.localizedDescription)")
            return nil
        }
        let batch = Batch(label: label, names: names, sources: sources, archive: archive)
        onTeardown("planted \(label) batch") { [weak self] in
            await self?.sweep(batch)
        }
        return batch
    }

    private func importsWholeAndDeletesWhole(count: Int) async {
        guard let batch = plant("N", count: count) else { return }
        guard let baseline = await read({ _ in true }) else {
            skip("the vault or the system list did not answer before the import")
            return
        }
        log("before the import: \(baseline.reading.line)")
        guard let imported = await importsWhole(batch) else { return }
        let deleted = await deletesWhole(batch.names, baseline: baseline.reading)
        measured[count] = (imported, deleted)
    }

    private func mismatched(_ batch: Batch) async -> [String]? {
        guard case .configs(let configs) = await vault.readAll() else { return nil }
        return batch.names.filter { tunnelName in
            guard let source = batch.sources[tunnelName],
                  let payload = configs.first(where: { $0.name == tunnelName }) else { return true }
            return payload.wireguard != source.wireguard || payload.wstunnel != source.wstunnel
        }
    }

    private func importsWhole(_ batch: Batch) async -> Imported? {
        let names = batch.names
        let isRun = { (name: String) in names.contains(name) }
        let watched = await watching(
            { await TunnelBulkImport.run([batch.archive], into: tunnels) },
            settling: isRun,
            until: { $0.agree && $0.rows.count == names.count }
        )
        let report = watched.result
        log(Self.timing("import", watched.took, count: report.added.count))
        log(notifications("import", watched.changes))

        check(report.added == names && report.skipped.isEmpty,
              "every entry of the \(names.count)-entry archive was added, in label order, and nothing was reported (added=\(report.added.count), skipped=\(report.skipped.map { "\($0.label): \($0.skip)" }))")

        let held = watched.settled.reading
        check(held.map { $0.agree && $0.rows.count == names.count } == true,
              "the live list, the system's entries and the vault hold the same \(names.count) ids, each once (\(held?.line ?? "unreadable"), \(Self.after(watched.settled, "agreed")))")

        if let mismatched = await mismatched(batch) {
            check(mismatched.isEmpty,
                  "every payload in the vault is the configuration its entry carried, the Ghost ones with their Wstunnel part (mismatched=\(mismatched.count))")
        } else {
            fail("the vault did not answer the payload comparison")
        }

        let painted = tunnels.tunnels.filter { isRun($0.name) }.map { "\($0.status)" }
        log("rows painted after the import: \(Dictionary(grouping: painted) { $0 }.mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        guard !report.added.isEmpty else { return nil }
        return Imported(
            each: Self.milliseconds(watched.took) / Double(report.added.count),
            changes: watched.changes,
            agreed: watched.settled
        )
    }

    private func deletesWhole(_ names: [String], baseline: TunnelStoreReading) async -> Deleted {
        let isRun = { (name: String) in names.contains(name) }
        let rows = TunnelListRules.ordered(tunnels.tunnels.filter { isRun($0.name) }, saved: [], id: \.id)
        let targets = TunnelBulkDelete.targets(rows, marked: Set(rows.map(\.id)))
        var progress: [Int] = []
        let watched = await watching(
            { await TunnelBulkDelete.run(targets, in: tunnels) { progress.append($0) } },
            settling: isRun,
            until: \.isEmpty
        )
        let report = watched.result
        log(Self.timing("delete", watched.took, count: targets.count))
        log(notifications("delete", watched.changes))

        check(!targets.isEmpty
                && report.deleted == targets.map(\.name)
                && report.skipped.isEmpty
                && progress == Array(1...targets.count),
              "the bulk delete took every planted row in list order, skipped none and counted each once (targets=\(targets.count), deleted=\(report.deleted.count), skipped=\(report.skipped.map { "\($0.name): \($0.skip)" }), progress last=\(progress.last ?? 0))")

        let left = watched.settled.reading
        check(left?.isEmpty == true,
              "none of the three real stores holds a planted tunnel (\(left?.line ?? "unreadable"), \(Self.after(watched.settled, "emptied")))")

        let everything = await settled({ _ in true }, until: {
            Set($0.rows) == Set(baseline.rows) && Set($0.entries) == Set(baseline.entries) && Set($0.payloads) == Set(baseline.payloads)
        }).reading
        check(everything.map {
                  Set($0.rows) == Set(baseline.rows)
                      && Set($0.entries) == Set(baseline.entries)
                      && Set($0.payloads) == Set(baseline.payloads)
              } == true,
              "the user's own tunnels are where they were: the three stores read the same ids as before the import (before \(baseline.line), now \(everything?.line ?? "unreadable"))")
        return Deleted(
            each: Self.milliseconds(watched.took) / Double(max(targets.count, 1)),
            changes: watched.changes,
            emptied: watched.settled
        )
    }

    private func compare(_ count: Int, with base: Int) {
        guard let large = measured[count], let small = measured[base] else {
            log("no comparison with the \(base)-tunnel batch: one of the two batches did not finish")
            return
        }
        let each = { (value: Double) in String(format: "%.1f", value) }
        let perTunnel = { (changes: Int, tunnels: Int) in String(format: "%.2f", Double(changes) / Double(tunnels)) }
        let after = { (settled: Settled) in
            settled.after.map { "\(String(format: "%.0f", $0)) ms on read \(settled.reads)" } ?? "not within the wait"
        }
        log("per tunnel, \(base) → \(count): import \(each(small.imported.each)) → \(each(large.imported.each)) ms, delete \(each(small.deleted.each)) → \(each(large.deleted.each)) ms")
        log("notifications per tunnel, \(base) → \(count): import \(perTunnel(small.imported.changes, base)) → \(perTunnel(large.imported.changes, count)), delete \(perTunnel(small.deleted.changes, base)) → \(perTunnel(large.deleted.changes, count))")
        log("after the batch returned, \(base) → \(count): stores agreed \(after(small.imported.agreed)) → \(after(large.imported.agreed)), emptied \(after(small.deleted.emptied)) → \(after(large.deleted.emptied))")
    }

    // MARK: - Step E

    private func aDeleteAndAnImportThatOverlapKeepTheirOwnRows() async {
        guard let setA = plant("A", count: overlapDeleted), let setB = plant("B", count: overlapImported) else { return }
        guard let baseline = await read({ _ in true }) else {
            skip("the vault or the system list did not answer before the import")
            return
        }
        log("before the import: \(baseline.reading.line)")
        let recorder = ChangeRecorder()
        recorder.start()
        defer { recorder.stop() }
        guard let listedA = await listed(setA) else { return }
        let timing = await overlaps(listedA.targets, with: setB)
        recorder.stop()
        for line in OverlapArrivals.lines(recorder.arrivals, listedAt: listedA.returned, timing: timing,
                                          setA: Set(setA.names), setB: Set(setB.names)) {
            log(line)
        }
        _ = await deletesWhole(setB.names, baseline: baseline.reading)
    }

    private func listed(_ setA: Batch) async -> (targets: [TunnelContainer], returned: ContinuousClock.Instant)? {
        let namesA = Set(setA.names)
        let report = await TunnelBulkImport.run([setA.archive], into: tunnels)
        let returned = ContinuousClock.now
        let ready = await settled({ namesA.contains($0) }, until: { $0.agree && $0.rows.count == namesA.count })
        let rows = TunnelListRules.ordered(tunnels.tunnels.filter { namesA.contains($0.name) }, saved: [], id: \.id)
        let targets = TunnelBulkDelete.targets(rows, marked: Set(rows.map(\.id)))
        guard report.added == setA.names, report.skipped.isEmpty, ready.after != nil, targets.count == namesA.count else {
            fail("set A could not be listed whole before the overlap (added=\(report.added.count), skipped=\(report.skipped.count), targets=\(targets.count), \(ready.reading?.line ?? "unreadable"))")
            return nil
        }
        log("set A listed: \(ready.reading?.line ?? "unreadable")")
        return (targets, returned)
    }

    private func overlaps(_ targets: [TunnelContainer], with setB: Batch) async -> OverlapTiming {
        let namesA = Set(targets.map(\.name))
        let namesB = Set(setB.names)
        let isPlanted = { (name: String) in namesA.contains(name) || namesB.contains(name) }
        let manager = tunnels
        let archiveB = setB.archive
        let seen = Samples()
        let watched = await watching(
            {
                let started = ContinuousClock.now
                let deleting = Task { @MainActor in
                    let report = await TunnelBulkDelete.run(targets, in: manager) { done in
                        seen.progress.append(done)
                        seen.progressAt.append(.now)
                        seen.listedOfB.append(manager.tunnels.filter { namesB.contains($0.name) }.count)
                    }
                    return (report, ContinuousClock.now - started)
                }
                let importing = Task { @MainActor in
                    let report = await TunnelBulkImport.run([archiveB], into: manager)
                    return (report, ContinuousClock.now - started)
                }
                let (deleted, deleteTook) = await deleting.value
                let (imported, importTook) = await importing.value
                return Overlap(deleted: deleted, deleteTook: deleteTook, imported: imported, importTook: importTook)
            },
            settling: isPlanted,
            until: { $0.agree && $0.rows.count == namesB.count }
        )
        let overlap = watched.result
        log(Self.timing("delete of set A, from the common start", overlap.deleteTook, count: targets.count))
        log(Self.timing("import of set B, from the common start", overlap.importTook, count: overlap.imported.added.count))
        log(notifications("overlap", watched.changes))

        let midway = seen.listedOfB.filter { $0 > 0 && $0 < namesB.count }
        check(!midway.isEmpty,
              "the two batches overlapped: set B rows were arriving on the live list while the delete was counting (B rows listed at the delete's progress: first \(seen.listedOfB.first ?? -1), last \(seen.listedOfB.last ?? -1), midway samples \(midway.count) of \(seen.listedOfB.count))")

        check(overlap.deleted.deleted == targets.map(\.name)
                && overlap.deleted.skipped.isEmpty
                && seen.progress == Array(1...targets.count),
              "the delete took every row of set A in list order, skipped none and counted each once (targets=\(targets.count), deleted=\(overlap.deleted.deleted.count), skipped=\(overlap.deleted.skipped.map { "\($0.name): \($0.skip)" }), progress last=\(seen.progress.last ?? 0))")

        check(overlap.imported.added == setB.names && overlap.imported.skipped.isEmpty,
              "the import added every entry of set B in label order and reported nothing (added=\(overlap.imported.added.count), skipped=\(overlap.imported.skipped.map { "\($0.label): \($0.skip)" }))")

        let held = watched.settled.reading
        let listed = tunnels.tunnels.map(\.name).filter(isPlanted)
        check(held.map { $0.agree && $0.rows.count == namesB.count } == true && Set(listed) == namesB,
              "the live list, the system's entries and the vault hold exactly set B's \(namesB.count) ids, each once, and nothing of set A (\(held?.line ?? "unreadable"), set A rows left \(listed.filter { namesA.contains($0) }.count), \(Self.after(watched.settled, "agreed")))")

        if let mismatched = await mismatched(setB) {
            check(mismatched.isEmpty,
                  "every set B payload in the vault is the configuration its entry carried, the Ghost ones with their Wstunnel part (mismatched=\(mismatched.count))")
        } else {
            fail("the vault did not answer the payload comparison")
        }

        var beganAt: [String: ContinuousClock.Instant] = [:]
        for (index, target) in targets.enumerated() {
            if index == 0 {
                beganAt[target.name] = watched.started
            } else if index - 1 < seen.progressAt.count {
                beganAt[target.name] = seen.progressAt[index - 1]
            }
        }
        return OverlapTiming(started: watched.started, windowEnd: watched.returned + changeWindow, beganAt: beganAt)
    }

    // MARK: - Teardown

    private func sweep(_ batch: Batch) async {
        let planted = Set(batch.names)
        guard let left = await read({ planted.contains($0) }) else {
            for tunnelName in batch.names {
                guard let config = batch.sources[tunnelName] else { continue }
                await sweepPlantedTunnel(id: config.id, name: tunnelName)
            }
            return
        }
        let ids = Set(left.reading.rows + left.reading.entries + left.reading.payloads)
        guard !ids.isEmpty else {
            log("teardown: the \(batch.names.count) planted tunnels of \(batch.label) — all three stores already clean")
            return
        }
        for id in ids {
            await sweepPlantedTunnel(id: id, name: left.names[id] ?? "\(Self.prefix)\(id)")
        }
    }
}
#endif
