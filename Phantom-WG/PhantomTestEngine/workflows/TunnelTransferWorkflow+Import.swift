// Tunnel Transfer: Import
//
// The list's bulk import (package 4d), driven through `TunnelBulkImport.run`
// over files the step writes into a folder of its own and a
// `TunnelsManager` over a `FakeSlotFactory`, as Tunnel Add does. The
// system's file importer is the user-facing surface and is tried by hand.
// Mac 2.2.1's Tunnel Transfer A and C are the source; H and J are iOS's.
//
// Scenarios:
//
//   G — Files And A Zip Import Into One List
//       A valid .conf, a broken one, one whose name the list already holds
//       and a zip carrying a Ghost .conf beside three AppleDouble entries
//       and a text file: one entry under `__MACOSX/` and named `._`, one
//       only named `._`, one only under `__MACOSX/`. The valid file and the
//       zip's .conf are added; the broken file is reported with its parse
//       error and the taken name as a name clash; the AppleDouble entries
//       and the text file are passed over.
//
//   H — The Content Decides, Not The Name
//       A zip saved as "archive.conf" is read as an archive and its .conf
//       is added; a .conf saved as "plain.zip" is read as a .conf and added
//       under that name; a .conf saved as "Kept.conf 2", as the Files app
//       names a kept duplicate, is added under that name. The archive's
//       second entry ends `.CONF` and spells a letter decomposed (S and a
//       combining cedilla): it is read and added under the composed name
//       with the suffix taken off. A file past 64 KB is reported as too
//       large and bytes that are not UTF-8 as not text.
//
//   I — An Exported Archive Imports Back The Same
//       A Standalone and a Ghost tunnel are exported through the bulk
//       export, which hands an archive; the archive, written to a file,
//       imports into an empty list, and each tunnel comes back with its
//       name and its WireGuard and Wstunnel configuration.
//
//   J — Every Picked File's Access Is Released
//       Over a recording access that refuses one file, a .conf, a zip, the
//       refused .conf and a file that is not there are imported: each one's
//       access is asked for once, and released once where it was granted.
//       The file that is not there is reported as unreadable.

#if DEBUG
import Foundation

extension TunnelTransferWorkflow {

    /// What a recording access was asked: the URLs started and stopped.
    final class AccessLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var startedPaths: [String] = []
        private var stoppedPaths: [String] = []
        private let refused: Set<String>

        /// `refusing` names the files whose access this ledger answers false.
        init(refusing refused: Set<String> = []) {
            self.refused = refused
        }

        var started: [String] { lock.withLock { startedPaths } }
        var stopped: [String] { lock.withLock { stoppedPaths } }

        var access: PickedFileAccess {
            PickedFileAccess(
                start: { url in
                    self.lock.withLock { self.startedPaths.append(url.lastPathComponent) }
                    return !self.refused.contains(url.lastPathComponent)
                },
                stop: { url in self.lock.withLock { self.stoppedPaths.append(url.lastPathComponent) } }
            )
        }
    }

    private func importFolder() -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("te-import-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        onTeardown("remove the step's import folder") { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func emptyList() -> TunnelsManager {
        TunnelsManager(tunnelProviders: [], providerFactory: FakeSlotFactory(canned: []))
    }

    private func write(_ files: [(name: String, data: Data)], into folder: URL) -> [URL]? {
        do {
            return try files.map { file in
                let url = folder.appendingPathComponent(file.name)
                try file.data.write(to: url)
                return url
            }
        } catch {
            return nil
        }
    }

    private func confData(_ config: TunnelConfig) -> Data {
        TunnelConfFile.data(config.asConfString())
    }

    // MARK: - Steps

    func filesAndAZipImportIntoOneList() async {
        guard let folder = importFolder() else {
            fail("the temporary folder could not be made")
            return
        }
        guard let configA = TestConfigFactory.throwaway(name: "TE-Import-A"),
              let configB = TestConfigFactory.throwaway(name: "TE-Import-B", ghost: true),
              let planted = TestConfigFactory.throwaway(name: "TE-Import-Taken"),
              let rival = TestConfigFactory.throwaway(name: "TE-Import-Taken") else {
            fail("the config factory did not produce the throwaways this step needs")
            return
        }
        let list = emptyList()
        do {
            _ = try await list.add(config: planted)
        } catch {
            skip("environment: the planted name could not be added (\(error.localizedDescription))")
            return
        }
        guard let bundle = try? ZipArchive.archive([
            ("bundle/TE-Import-B.conf", confData(configB)),
            ("__MACOSX/bundle/._TE-Import-B.conf", Data([0, 5, 22, 7])),
            ("bundle/._TE-Import-B.conf", Data([0, 5, 22, 7])),
            ("__MACOSX/bundle/TE-Import-B.conf", Data([0, 5, 22, 7])),
            ("bundle/notes.txt", Data("notes\n".utf8))
        ]), let urls = write([
            ("TE-Import-A.conf", confData(configA)),
            ("TE-Import-Broken.conf", Data("[Interface]\nPrivateKey = broken\n".utf8)),
            ("TE-Import-Taken.conf", confData(rival)),
            ("bundle.zip", bundle)
        ], into: folder) else {
            fail("the files this step imports could not be written")
            return
        }

        let report = await TunnelBulkImport.run(urls, into: list)
        log("added \(report.added); skipped \(report.skipped.map { "\($0.label): \($0.skip)" })")
        let broken = report.skipped.first { $0.label == "TE-Import-Broken.conf" }?.skip
        let taken = report.skipped.first { $0.label == "TE-Import-Taken.conf" }?.skip
        let rows = list.tunnels.map(\.name)

        check(Set(report.added) == ["TE-Import-A", "TE-Import-B"],
              "the valid file and the zip's Ghost .conf were added (added=\(report.added))")
        check(broken == .parse(.noPeerSection),
              "the broken file was reported with its parse error (\(String(describing: broken)))")
        check(taken == .addFailed(TunnelManagementError.tunnelAlreadyExistsWithThatName.localizedDescription),
              "the file whose name the list holds was reported as a name clash (\(String(describing: taken)))")
        check(report.skipped.count == 2,
              "only those two were reported: the three AppleDouble entries and notes.txt were passed over"
              + " (skipped=\(report.skipped.count))")
        check(rows.filter { $0 == "TE-Import-Taken" }.count == 1 && rows.contains("TE-Import-A") && rows.contains("TE-Import-B"),
              "the list holds both new tunnels and the taken name once (rows=\(rows))")
    }

    func theContentDecidesNotTheName() async {
        guard let folder = importFolder() else {
            fail("the temporary folder could not be made")
            return
        }
        guard let inner = TestConfigFactory.throwaway(name: "inner"),
              let plain = TestConfigFactory.throwaway(name: "plain"),
              let kept = TestConfigFactory.throwaway(name: "kept"),
              let archive = try? ZipArchive.archive([("inner.conf", confData(inner)),
                                                     ("S\u{327}ube.CONF", confData(kept))]) else {
            fail("the config factory or the archive writer did not produce what this step needs")
            return
        }
        var large = confData(plain)
        large.append(Data(repeating: 0x23, count: 64 * 1024))
        guard let urls = write([
            ("archive.conf", archive),
            ("plain.zip", confData(plain)),
            ("Kept.conf 2", confData(kept)),
            ("large.conf", large),
            ("binary.conf", Data([0xFF, 0xFE, 0x00, 0xC3]))
        ], into: folder) else {
            fail("the files this step imports could not be written")
            return
        }

        let report = await TunnelBulkImport.run(urls, into: emptyList())
        log("added \(report.added); skipped \(report.skipped.map { "\($0.label): \($0.skip)" })")
        check(report.added.contains("inner"),
              "the zip saved as archive.conf was read as an archive and its .conf added (added=\(report.added))")
        check(report.added.contains("plain.zip"),
              "the .conf saved as plain.zip was read as a .conf and added under that name (added=\(report.added))")
        check(report.added.contains("Kept.conf 2"),
              "the .conf saved as \"Kept.conf 2\" was added under that name (added=\(report.added))")
        let composed = report.added.first { $0.hasSuffix("ube") }.map { $0.unicodeScalars.map(\.value) }
        check(composed == [0x15E, 0x75, 0x62, 0x65],
              "the archive's entry S\u{327}ube.CONF, its name decomposed, was read and added as \u{15E}ube, composed"
              + " (scalars=\(composed ?? []))")
        let oversized = report.skipped.first { $0.label == "large.conf" }?.skip
        let binary = report.skipped.first { $0.label == "binary.conf" }?.skip
        check(oversized == .tooLarge && binary == .notText && report.added.count == 4,
              "the file past 64 KB is too large and the bytes that are not UTF-8 are not text"
              + " (large=\(String(describing: oversized)), binary=\(String(describing: binary)),"
              + " added=\(report.added.count))")
    }

    func anExportedArchiveImportsBackTheSame() async {
        guard let folder = importFolder() else {
            fail("the temporary folder could not be made")
            return
        }
        guard let standalone = TestConfigFactory.throwaway(name: "TE-Round-Standalone"),
              let ghost = TestConfigFactory.throwaway(name: "TE-Round-Ghost", ghost: true) else {
            fail("the config factory did not produce the two throwaways this step needs")
            return
        }
        let originals = [standalone, ghost]
        let tunnels = originals.map { TunnelContainer(tunnel: FakeSlotProvider(config: $0)) }
        let outcome = await bulkExport(tunnels, answering: .granted, Ledger())
        guard let file = archive(handedBy: outcome) else { return }
        guard let urls = write([(file.name, file.data)], into: folder) else {
            fail("the archive could not be written into the step's folder")
            return
        }

        let list = emptyList()
        let report = await TunnelBulkImport.run(urls, into: list)
        check(report.skipped.isEmpty && Set(report.added) == Set(originals.map(\.name)),
              "the archive imports every tunnel and reports nothing (added=\(report.added), skipped=\(report.skipped.count))")
        for original in originals {
            let back = list.tunnels.first { $0.name == original.name }?.tunnelConfig
            let sameWireguard = back?.wireguard == original.wireguard
            let sameWstunnel = back != nil && back?.wstunnel == original.wstunnel
            check(sameWireguard && sameWstunnel,
                  "\(original.name) comes back with its WireGuard and Wstunnel configuration"
                  + " (read=\(back != nil), same WireGuard=\(sameWireguard), same Wstunnel=\(sameWstunnel))")
        }
    }

    func everyPickedFilesAccessIsReleased() async {
        guard let folder = importFolder() else {
            fail("the temporary folder could not be made")
            return
        }
        guard let config = TestConfigFactory.throwaway(name: "TE-Access"),
              let archive = try? ZipArchive.archive([("TE-Access-Zipped.conf", confData(config))]),
              var urls = write([("TE-Access.conf", confData(config)), ("TE-Access.zip", archive),
                                ("TE-Access-Refused.conf", confData(config))], into: folder) else {
            fail("the files this step imports could not be written")
            return
        }
        urls.append(folder.appendingPathComponent("TE-Access-Missing.conf"))
        let ledger = AccessLedger(refusing: ["TE-Access-Refused.conf"])
        let report = await TunnelBulkImport.run(urls, into: emptyList(), access: ledger.access)
        let missing = report.skipped.first { $0.label == "TE-Access-Missing.conf" }?.skip
        check(missing == .unreadable, "the file that is not there is reported as unreadable (\(String(describing: missing)))")
        let names = urls.map(\.lastPathComponent).sorted()
        check(ledger.started.sorted() == names && ledger.stopped.sorted() == names.filter { $0 != "TE-Access-Refused.conf" },
              "each picked file's access was asked for once, and released once where it was granted"
              + " (started=\(ledger.started.sorted()), stopped=\(ledger.stopped.sorted()))")
    }
}
#endif
