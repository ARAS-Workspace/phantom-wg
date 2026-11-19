// Tunnel Transfer
//
// How a tunnel's configuration leaves the app as a file and comes back in.
// Mac 2.2.1's Tunnel Transfer drives the bulk import and export; on iOS the
// detail's single `.conf` export came first (package 4b), the list's zip
// export followed (4c), and the import (4d) lives in
// TunnelTransferWorkflow+Import.
//
// A, B, E and F run over `FakeSlotProvider`s of the step's own, and the
// owner check is answered by a closure, as Private Data does. C stages into
// a folder of its own and answers the picker's delegate calls itself. D
// stages into the app's real staging folder and runs the launch path,
// `TunnelsManager.create()`, as Tunnel Load does. The picker's sheet and
// the Files app are the user-facing surface and are tried by hand.
//
// Scenarios:
//
//   A — The Detail Export Hands The .conf Bytes
//       A Standalone and a Ghost tunnel, each named with a slash, a colon
//       and Turkish letters, are exported with the owner granting. The
//       document holds the tunnel's `.conf` text and a line end, reads back
//       through `ConfParser` to the same WireGuard and Wstunnel
//       configuration, and is named by the rule (slash and colon to
//       hyphens, `.conf` added). The app declares no type for `.conf`;
//       what the extension resolves to on this system is logged.
//
//   B — The Detail Export Asks The Owner First
//       A declined check hands no document and names no failure; a failed
//       check hands none and names its failure once; each is asked once
//       with the export's reason. A tunnel that reads no configuration
//       hands no document, and its owner is not asked.
//
//   C — The Staged File Lives Until The Picker Answers
//       Staged, the folder holds the file alone, with the document's bytes
//       and mode 0600. A cancelled answer removes the folder and tells the
//       caller nothing was saved; staged again, a picked answer removes it
//       too and tells the caller the file was saved.
//
//   D — A Leftover Staged File Is Swept At Launch
//       A file is left in the app's staging folder, as a run that ended
//       with the picker open leaves it. After `TunnelsManager.create()` the
//       folder is gone.
//
//   E — The Bulk Export Archives Every Readable Tunnel
//       Four listed tunnels, out of order: "Ev Ağı", "Ağ Kuzey", "ev ağı"
//       and one whose configuration reads nothing. With the owner granting,
//       the archive is named phantom-wg-export.zip and holds the three
//       readable tunnels' `.conf` bytes, sorted by tunnel name, the name that
//       clashes without regard to case taking " 2"; the unreadable tunnel is
//       reported as unread, three of four counted.
//
//   F — The Bulk Export Asks The Owner First
//       A declined check archives nothing and names no failure; a failed
//       check archives nothing and names its failure once. With the owner
//       granting, a list whose tunnels all read nothing archives nothing
//       and reports each of them, sorted, as unread.
//
// G to J, the import, are described in TunnelTransferWorkflow+Import.

#if DEBUG
import Foundation
import UIKit
import UniformTypeIdentifiers

final class TunnelTransferWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Transfer (Files In And Out)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("The Detail Export Hands The .conf Bytes", theDetailExportHandsTheConfBytes),
            WorkflowStep("The Detail Export Asks The Owner First", theDetailExportAsksTheOwnerFirst),
            WorkflowStep("The Staged File Lives Until The Picker Answers", theStagedFileLivesUntilThePickerAnswers),
            WorkflowStep("A Leftover Staged File Is Swept At Launch", aLeftoverStagedFileIsSweptAtLaunch),
            WorkflowStep("The Bulk Export Archives Every Readable Tunnel", theBulkExportArchivesEveryReadableTunnel),
            WorkflowStep("The Bulk Export Asks The Owner First", theBulkExportAsksTheOwnerFirst),
            WorkflowStep("Files And A Zip Import Into One List", filesAndAZipImportIntoOneList),
            WorkflowStep("The Content Decides, Not The Name", theContentDecidesNotTheName),
            WorkflowStep("An Exported Archive Imports Back The Same", anExportedArchiveImportsBackTheSame),
            WorkflowStep("Every Picked File's Access Is Released", everyPickedFilesAccessIsReleased)
        ]
    }

    static let reason = "TE export reason"

    /// What one export left behind at the owner check.
    @MainActor
    final class Ledger {
        var asked: [String] = []
        var failures: [String] = []
    }

    /// One owner answer of step B and the failures it must name.
    private struct OwnerCase {
        let label: String
        let outcome: PrivateDataAuthorization.Outcome
        let failures: [String]
    }

    private func export(
        _ tunnel: TunnelContainer,
        answering outcome: PrivateDataAuthorization.Outcome,
        _ ledger: Ledger
    ) async -> ExportedFile? {
        await TunnelConfFile.document(
            of: tunnel,
            reason: Self.reason,
            authorize: { reason in
                ledger.asked.append(reason)
                return outcome
            },
            onFailure: { ledger.failures.append($0) }
        )
    }

    func bulkExport(
        _ tunnels: [TunnelContainer],
        answering outcome: PrivateDataAuthorization.Outcome,
        _ ledger: Ledger
    ) async -> TunnelBulkExport.Outcome {
        await TunnelBulkExport.run(
            tunnels,
            reason: Self.reason,
            authorize: { reason in
                ledger.asked.append(reason)
                return outcome
            },
            onFailure: { ledger.failures.append($0) }
        )
    }

    /// A listed tunnel whose configuration reads nothing.
    private func unreadable(named name: String) -> TunnelContainer {
        let provider = FakeSlotProvider(config: nil)
        provider.localizedDescription = name
        return TunnelContainer(tunnel: provider)
    }

    private func file(named name: String) -> ExportedFile? {
        TestConfigFactory.throwaway(name: name).map {
            ExportedFile(data: TunnelConfFile.data($0.asConfString()), name: TunnelConfFile.fileName(for: $0.name))
        }
    }

    // MARK: - Steps

    func theDetailExportHandsTheConfBytes() async {
        for ghost in [false, true] {
            let mode = ghost ? "Ghost" : "Standalone"
            guard var config = TestConfigFactory.throwaway(name: "TE-Transfer-\(mode)", ghost: ghost) else {
                fail("the config factory produced no \(mode) throwaway")
                continue
            }
            config.name = "Ev/Ağı: İç \(mode)"
            let tunnel = TunnelContainer(tunnel: FakeSlotProvider(config: config))
            guard let document = await export(tunnel, answering: .granted, Ledger()) else {
                fail("\(mode): the granted export handed no document")
                continue
            }
            check(document.data == Data((config.asConfString() + "\n").utf8),
                  "\(mode): the document holds the tunnel's .conf text and a line end (\(document.data.count) bytes)")
            let text = String(bytes: document.data, encoding: .utf8)
            let back = text.flatMap { TestConfigFactory.validated($0, name: "TE-Transfer-Back").config }
            check(back?.wireguard == config.wireguard && back?.wstunnel == config.wstunnel,
                  "\(mode): it reads back through ConfParser to the same WireGuard and Wstunnel configuration"
                  + " (read=\(back != nil))")
            check(document.name == "Ev-Ağı- İç \(mode).conf",
                  "\(mode): it is named by the rule, slash and colon to hyphens and .conf added (\(document.name))")
        }
        log("on this system the conf extension resolves to \(UTType(filenameExtension: "conf")?.identifier ?? "none")")
    }

    func theDetailExportAsksTheOwnerFirst() async {
        guard let config = TestConfigFactory.throwaway(name: "TE-Transfer-Owner") else {
            fail("the config factory produced no throwaway")
            return
        }
        let tunnel = TunnelContainer(tunnel: FakeSlotProvider(config: config))
        let cases = [
            OwnerCase(label: "a declined check", outcome: .declined, failures: []),
            OwnerCase(label: "a failed check", outcome: .failed("TE owner check failed"), failures: ["TE owner check failed"])
        ]
        for entry in cases {
            let ledger = Ledger()
            let document = await export(tunnel, answering: entry.outcome, ledger)
            check(document == nil && ledger.asked == [Self.reason] && ledger.failures == entry.failures,
                  "after \(entry.label) no document is handed, the check was asked once with the export's reason"
                  + " and the failures named are \(entry.failures) (document=\(document != nil), asked=\(ledger.asked),"
                  + " failures=\(ledger.failures))")
        }

        let unread = TunnelContainer(tunnel: FakeSlotProvider(config: nil))
        let ledger = Ledger()
        let document = await export(unread, answering: .granted, ledger)
        check(document == nil && ledger.asked.isEmpty,
              "a tunnel that reads no configuration hands no document and its owner is not asked"
              + " (document=\(document != nil), asked=\(ledger.asked.count))")
    }

    func theStagedFileLivesUntilThePickerAnswers() async {
        guard let file = file(named: "TE-Transfer-Stage") else {
            fail("the config factory produced no throwaway")
            return
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("te-export-\(UUID().uuidString)", isDirectory: true)
        onTeardown("remove the step's staging folder") { TunnelExportPicker.sweep(folder) }
        var answers: [Bool] = []
        let exporter = TunnelExportPicker(folder: folder) { answers.append($0) }

        for answer in ["cancelled", "picked"] {
            let url: URL
            do {
                url = try exporter.stage(file)
            } catch {
                fail("the file could not be staged (\(error.localizedDescription))")
                return
            }
            let listed = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int ?? -1
            check(listed == [file.name] && (try? Data(contentsOf: url)) == file.data && mode == 0o600,
                  "staged before the \(answer) answer, the folder holds the file alone with its bytes and mode 0600"
                  + " (files=\(listed), mode=\(String(mode, radix: 8)))")

            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: false)
            if answer == "cancelled" {
                exporter.documentPickerWasCancelled(picker)
            } else {
                exporter.documentPicker(picker, didPickDocumentsAt: [url])
            }
            check(!FileManager.default.fileExists(atPath: folder.path),
                  "after the \(answer) answer the staging folder is gone")
        }
        check(answers == [false, true],
              "the caller heard the cancelled answer as not saved and the picked answer as saved (answers=\(answers))")
    }

    func aLeftoverStagedFileIsSweptAtLaunch() async {
        guard let file = file(named: "TE-Transfer-Leftover") else {
            fail("the config factory produced no throwaway")
            return
        }
        let folder = TunnelExportPicker.stagingFolder
        onTeardown("remove a leftover staged file") { TunnelExportPicker.sweep(folder) }
        let staged: URL
        do {
            staged = try TunnelExportPicker(folder: folder).stage(file)
        } catch {
            fail("the file could not be staged (\(error.localizedDescription))")
            return
        }
        guard check(FileManager.default.fileExists(atPath: staged.path),
                    "a file is left in the app's staging folder, as a run that ended with the picker open leaves it") else { return }
        do {
            _ = try await TunnelsManager.create()
        } catch {
            fail("the launch path was refused (\(error.localizedDescription))")
            return
        }
        check(!FileManager.default.fileExists(atPath: folder.path),
              "after the launch path TunnelsManager.create() the staging folder is gone")
    }

    func theBulkExportArchivesEveryReadableTunnel() async {
        let names = ["Ev Ağı", "Ağ Kuzey", "ev ağı"]
        let configs = names.compactMap { TestConfigFactory.throwaway(name: $0) }
        guard configs.count == names.count else {
            fail("the config factory did not produce the three throwaways this step needs")
            return
        }
        let tunnels = configs.map { TunnelContainer(tunnel: FakeSlotProvider(config: $0)) } + [unreadable(named: "Okunmaz")]
        let outcome = await bulkExport(tunnels, answering: .granted, Ledger())
        guard case .archived(let file, let count, let total, let unread) = outcome else {
            fail("the granted bulk export archived nothing (\(outcome))")
            return
        }
        check(file.name == "phantom-wg-export.zip" && count == 3 && total == 4 && unread == ["Okunmaz"],
              "the archive is phantom-wg-export.zip, three of four counted, the unreadable tunnel reported as unread"
              + " (name=\(file.name), count=\(count), total=\(total), unread=\(unread))")

        let limits = ZipArchive.Limits(listed: 64, selected: 64, entryBytes: 64 * 1024)
        guard let entries = try? ZipArchive.entries(in: file.data, limits: limits, pages: .unitedStates, where: { _ in true }) else {
            fail("the archive's bytes did not read back")
            return
        }
        let paths = entries.map(\.path)
        // The plan sorts by tunnel name and numbers a clash after sorting,
        // so the order is read on the names with " 2" and ".conf" taken off.
        let stems = paths.map { $0.replacingOccurrences(of: " 2.conf", with: "").replacingOccurrences(of: ".conf", with: "") }
        let sorted = zip(stems, stems.dropFirst()).allSatisfy { $0.localizedStandardCompare($1) != .orderedDescending }
        check(paths.first == "Ağ Kuzey.conf" && sorted,
              "the entries are sorted by tunnel name (paths=\(paths))")
        check(Set(paths.map { $0.lowercased() }) == ["ağ kuzey.conf", "ev ağı.conf", "ev ağı 2.conf"]
                && paths.filter { $0.hasSuffix(" 2.conf") }.count == 1,
              "the name that clashes without regard to case takes \" 2\" (paths=\(paths))")
        let contents = Set(entries.compactMap { try? $0.content.get() })
        let expected = Set(configs.map { TunnelConfFile.data($0.asConfString()) })
        check(contents == expected && entries.count == 3,
              "the archive holds the three readable tunnels' .conf bytes (entries=\(entries.count))")
    }

    func theBulkExportAsksTheOwnerFirst() async {
        guard let config = TestConfigFactory.throwaway(name: "TE-Transfer-Bulk-Owner") else {
            fail("the config factory produced no throwaway")
            return
        }
        let tunnels = [TunnelContainer(tunnel: FakeSlotProvider(config: config))]
        let cases = [
            OwnerCase(label: "a declined check", outcome: .declined, failures: []),
            OwnerCase(label: "a failed check", outcome: .failed("TE owner check failed"), failures: ["TE owner check failed"])
        ]
        for entry in cases {
            let ledger = Ledger()
            let outcome = await bulkExport(tunnels, answering: entry.outcome, ledger)
            check(outcome == .declined && ledger.asked == [Self.reason] && ledger.failures == entry.failures,
                  "after \(entry.label) nothing is archived, the check was asked once with the export's reason"
                  + " and the failures named are \(entry.failures) (outcome=\(outcome), asked=\(ledger.asked),"
                  + " failures=\(ledger.failures))")
        }

        let unreadList = [unreadable(named: "Okunmaz B"), unreadable(named: "Okunmaz A")]
        let outcome = await bulkExport(unreadList, answering: .granted, Ledger())
        check(outcome == .nothing(unread: ["Okunmaz A", "Okunmaz B"]),
              "a list whose tunnels all read nothing archives nothing and reports each, sorted, as unread (\(outcome))")
    }
}
#endif
