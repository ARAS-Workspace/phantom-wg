// Archive Names
//
// How a ZIP entry's name is read, and what the app's own archive holds.
// No service, no tunnel: A and B write their fixture archive into a
// temporary folder and read it back through `ZipArchive.entries(at:)`; C
// builds the app's own archive in memory through `ZipArchive.archive(_:)`.
// Each step removes its folder. Mac 2.2.1's Archive Names is the source.
//
// Scenarios:
//
//   A — Windows Code Pages Read Turkish Names
//       Names in CP857 from FAT, NTFS and Unix hosts and in CP1254 from a
//       VFAT host read as Turkish under the TR region's pages; a UTF-8
//       name without the flag from a Unix host stays UTF-8; a byte the
//       chosen page leaves undefined reads in CP437; outside Turkey the
//       OEM name reads in CP437. The TR region picks pages 857 and 1254,
//       any other region 437 and 1252.
//
//   B — Unicode Path Field and UTF-8 Flag
//       Info-ZIP's Unicode path field wins over the raw name only while its
//       checksum matches the raw name; the UTF-8 flag wins over both while
//       the name is UTF-8, and a flagged name that is not reads as an
//       unflagged one.
//
//   C — Own Archive Round-Trips Turkish Names
//       `ZipArchive.archive` builds the archive in memory. Read from its
//       bytes, the Turkish names and contents come back as written, and
//       every entry carries the UTF-8 flag and is made by Unix with mode
//       0600. Written into the step's folder, the same bytes read back the
//       same through a file.
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
            WorkflowStep("Own Archive Round-Trips Turkish Names", ownArchiveRoundTrip)
        ]
    }

    // MARK: - Steps

    func windowsCodePages() async {
        report(ArchiveNameChecks.windowsCodePages)
    }

    func unicodePathField() async {
        report(ArchiveNameChecks.unicodePathField)
    }

    func ownArchiveRoundTrip() async {
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
