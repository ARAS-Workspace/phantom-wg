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
// Archive Names
//
// How a ZIP entry's name is read, and what the app's own archives write.
// No service, no tunnel: each step writes its archive into a temporary
// folder, reads it back through ZipArchive and removes the folder.
//
// Scenarios:
//
//   A — Windows Code Pages Read Turkish Names
//       Names in CP857 from FAT and NTFS hosts and in CP1254 from a VFAT
//       host read as Turkish under the TR region's pages; a UTF-8 name
//       without the flag from a Unix host stays UTF-8; a byte the chosen
//       page leaves undefined reads in CP437; outside Turkey the OEM name
//       reads in CP437.
//
//   B — Unicode Path Field and UTF-8 Flag
//       Info-ZIP's Unicode path field wins over the raw name only while its
//       checksum matches the raw name; the UTF-8 flag wins over both while
//       the name is UTF-8, and a flagged name that is not reads as an
//       unflagged one.
//
//   C — Own Archive Round-Trips Turkish Names
//       ZipArchive.write stores Turkish names with the UTF-8 flag, made by
//       Unix with mode 0600, and they read back as written.
//
// The checks live in ArchiveNameChecks.

#if DEBUG
import Foundation

final class ArchiveNamesWorkflow: TestWorkflow {
    override var displayName: String { "Archive Names" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Windows Code Pages Read Turkish Names", windowsCodePages),
            WorkflowStep("Unicode Path Field and UTF-8 Flag", unicodePathField),
            WorkflowStep("Own Archive Round-Trips Turkish Names", ownArchiveRoundTrip),
        ]
    }

    // MARK: - Steps

    private func windowsCodePages() async {
        report(ArchiveNameChecks.windowsCodePages)
    }

    private func unicodePathField() async {
        report(ArchiveNameChecks.unicodePathField)
    }

    private func ownArchiveRoundTrip() async {
        report(ArchiveNameChecks.ownArchiveRoundTrip)
    }

    private func report(_ checks: (URL) -> [ArchiveNameChecks.Outcome]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-names-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fail("the temporary folder could not be made: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        for outcome in checks(directory) {
            check(outcome.passed, "\(outcome.id) \(outcome.message)")
        }
    }
}
#endif
