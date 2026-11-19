// Tunnel Transfer
//
// How a tunnel's configuration leaves the app as a file. Mac 2.2.1's Tunnel
// Transfer drives the bulk import and export; on iOS the detail's single
// `.conf` export comes first (package 4b), and the bulk steps join as their
// packages land.
//
// A and B run over a `FakeSlotProvider` of the step's own, and the owner
// check is answered by a closure, as Private Data does. C stages into a
// folder of its own and answers the picker's delegate calls itself. D
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
//       and mode 0600. A cancelled answer removes the folder; staged again,
//       a picked answer removes it too.
//
//   D — A Leftover Staged File Is Swept At Launch
//       A file is left in the app's staging folder, as a run that ended
//       with the picker open leaves it. After `TunnelsManager.create()` the
//       folder is gone.

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
            WorkflowStep("A Leftover Staged File Is Swept At Launch", aLeftoverStagedFileIsSweptAtLaunch)
        ]
    }

    private static let reason = "TE export reason"

    /// What one export left behind at the owner check.
    @MainActor
    private final class Ledger {
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
        let exporter = TunnelExportPicker(folder: folder)

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
}
#endif
