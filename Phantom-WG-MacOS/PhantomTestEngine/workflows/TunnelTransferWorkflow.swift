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
// Tunnel Transfer
//
// The gear menu's bulk import and export, driven through `add()` and the
// vault's `readAll` the way the menu drives them, without the panels and
// the device owner prompt around them.
//
// Everything here runs over fabricated stores, as Tunnel Add does: a vault
// that answers at once and keeps what it is given, and a factory that
// mints the providers `add()` asks for. Nothing reaches the user's list or
// the real vault, and the export never reads the user's tunnels.
//
// Scenarios:
//
//   A — Files And A Zip Import Into One List
//       A valid .conf, a broken one, one whose name the list already holds
//       and a zip carrying a Ghost .conf beside an AppleDouble entry and a
//       text file. The valid file and the zip's .conf are added; the broken
//       file is reported with its parse error and the taken name as a name
//       clash; the AppleDouble entry and the text file are passed over.
//
//   B — Export Writes The Listed Tunnels' Payloads
//       The list from A is exported while the vault withholds one payload.
//       The archive holds each read payload's bytes, has mode 0600, and the
//       withheld tunnel is reported as unread.
//
//   C — An Exported Archive Imports Back The Same
//       B's archive is imported into an empty list: every tunnel comes back
//       with its WireGuard and Wstunnel configuration.
//
// B and C build on what A leaves; a step whose ground is missing skips.

#if DEBUG
import Foundation

final class TunnelTransferWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Transfer (Bulk Import And Export)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Files And A Zip Import Into One List", filesAndAZipImportIntoOneList),
            WorkflowStep("Export Writes The Listed Tunnels' Payloads", exportWritesTheListedPayloads),
            WorkflowStep("An Exported Archive Imports Back The Same", anExportedArchiveImportsBack),
        ]
    }

    private struct Imported {
        let manager: TunnelsManager
        let vault: FaultVaultClient
    }

    private let runTag = String(UUID().uuidString.prefix(8))
    private var directory: URL?
    private var imported: Imported?
    private var exported: URL?

    private var nameA: String { "TE-Transfer-A-\(runTag)" }
    private var nameB: String { "TE-Transfer-B-\(runTag)" }
    private var nameTaken: String { "TE-Transfer-Taken-\(runTag)" }
    private var nameBroken: String { "TE-Transfer-Broken-\(runTag)" }

    // MARK: - Rig

    private func answeringVault() -> FaultVaultClient {
        let vault = FaultVaultClient()
        vault.readAllAnswer = .answers(.configs([]))
        vault.readAnswer = .answers(.unreachable)
        vault.storeAnswer = .answers(.done)
        vault.deleteAnswer = .answers(.done)
        return vault
    }

    private func manager(over vault: FaultVaultClient) -> TunnelsManager {
        TunnelsManager(
            tunnelProviders: [],
            providerFactory: FakeSlotFactory(canned: []),
            vault: vault,
            observesSystemChanges: false
        )
    }

    private func workDirectory() -> URL? {
        if let directory { return directory }
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-transfer-\(runTag)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        onTeardown("transfer folder") {
            try? FileManager.default.removeItem(at: made)
        }
        directory = made
        return made
    }

    private func mode(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
    }

    // MARK: - Steps

    private func filesAndAZipImportIntoOneList() async {
        guard let folder = workDirectory() else {
            fail("the temporary folder could not be made")
            return
        }
        guard let configA = TestConfigFactory.throwaway(name: nameA),
              let configB = TestConfigFactory.throwaway(name: nameB, ghost: true),
              let planted = TestConfigFactory.throwaway(name: nameTaken),
              let rival = TestConfigFactory.throwaway(name: nameTaken) else {
            fail("the config factory did not produce the throwaways this step needs")
            return
        }
        let vault = answeringVault()
        let list = manager(over: vault)
        do {
            _ = try await list.add(config: planted)
        } catch {
            skip("environment: the planted name could not be added — \(error.localizedDescription)")
            return
        }

        do {
            try TunnelConfFile.write(configA.asConfString(), to: folder.appendingPathComponent("\(nameA).conf"))
            try TunnelConfFile.write("[Interface]\nPrivateKey = broken\n", to: folder.appendingPathComponent("\(nameBroken).conf"))
            try TunnelConfFile.write(rival.asConfString(), to: folder.appendingPathComponent("\(nameTaken).conf"))
            try ZipArchive.write([
                ("bundle/\(nameB).conf", TunnelConfFile.data(configB.asConfString())),
                ("__MACOSX/bundle/._\(nameB).conf", Data([0, 5, 22, 7])),
                ("bundle/notes.txt", Data("notes\n".utf8)),
            ], to: folder.appendingPathComponent("bundle.zip"))
        } catch {
            fail("the files this step imports could not be written: \(error.localizedDescription)")
            return
        }

        let urls = ["\(nameA).conf", "\(nameBroken).conf", "\(nameTaken).conf", "bundle.zip"]
            .map { folder.appendingPathComponent($0) }
        let report = await TunnelBulkImport.run(urls, into: list)
        log("added \(report.added); skipped \(report.skipped.map { "\($0.label): \($0.skip)" })")

        let broken = report.skipped.first { $0.label == "\(nameBroken).conf" }?.skip
        let taken = report.skipped.first { $0.label == "\(nameTaken).conf" }?.skip
        let rows = list.tunnels.map(\.name)

        check(Set(report.added) == [nameA, nameB],
              "the valid file and the zip's Ghost .conf were added (added=\(report.added))")
        check(broken == .parse(.noPeerSection),
              "the broken file was reported with its parse error (\(String(describing: broken)))")
        check(taken == .addFailed(TunnelManagementError.tunnelAlreadyExistsWithThatName.localizedDescription),
              "the file whose name the list holds was reported as a name clash (\(String(describing: taken)))")
        check(report.skipped.count == 2,
              "only those two were reported: the AppleDouble entry and notes.txt were passed over (skipped=\(report.skipped.count))")
        check(rows.filter { $0 == nameTaken }.count == 1 && rows.contains(nameA) && rows.contains(nameB),
              "the list holds both new tunnels and the taken name once (rows=\(rows.count))")
        check(Set(vault.storedConfigs.map(\.name)) == [nameA, nameB, nameTaken],
              "the vault holds the three payloads (stored=\(vault.storedConfigs.count))")

        imported = Imported(manager: list, vault: vault)
    }

    private func exportWritesTheListedPayloads() async {
        guard let imported, let folder = directory else {
            skip("the import step left no list to export")
            return
        }
        let readable = imported.vault.storedConfigs.filter { $0.name != nameTaken }
        imported.vault.readAllAnswer = .answers(.configs(readable))
        let archive = folder.appendingPathComponent("export.zip")

        let outcome = await TunnelBulkExport.run(imported.manager.tunnels, vault: imported.vault, to: archive)
        guard case .exported(let count, let total, let unread) = outcome else {
            fail("the export did not write an archive (\(outcome))")
            return
        }
        check(count == readable.count && total == imported.manager.tunnels.count && unread == [nameTaken],
              "the readable payloads were written and the withheld one reported unread (count=\(count), total=\(total), unread=\(unread))")

        let entries = (try? ZipArchive.entries(at: archive, limits: TunnelImportBatch.limits, pages: .unitedStates) { _ in true }) ?? []
        let written = Set(entries.compactMap { try? $0.content.get() })
        let expected = Set(readable.map { TunnelConfFile.data($0.asConfString()) })
        check(!written.isEmpty && written == expected,
              "each entry holds the bytes its vault payload writes as a .conf (entries=\(entries.count))")
        check(mode(archive) == 0o600,
              "the archive has mode 600 (\(String(mode(archive), radix: 8)))")

        exported = archive
    }

    private func anExportedArchiveImportsBack() async {
        guard let archive = exported, let imported else {
            skip("the export step left no archive to import")
            return
        }
        let originals = imported.vault.storedConfigs.filter { $0.name != nameTaken }
        let vault = answeringVault()
        let list = manager(over: vault)

        let report = await TunnelBulkImport.run([archive], into: list)
        check(report.skipped.isEmpty && report.added.count == originals.count,
              "the archive imported whole into an empty list (added=\(report.added.count), skipped=\(report.skipped.count))")
        let same = originals.allSatisfy { original in
            vault.storedConfigs.contains {
                $0.name == original.name && $0.wireguard == original.wireguard && $0.wstunnel == original.wstunnel
            }
        }
        check(same, "every tunnel came back with its WireGuard and Wstunnel configuration")
    }
}
#endif
