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
// Sanity Check
//
// Proves the harness is wired end to end against the LIVE services before
// anything else is measured. No server, no session raised: three daemons
// are asked who they are, the door's fuel is checked, and the vault is
// read twice — once for a Ghost config, once for a standalone one.
//
// It runs first in the catalogue because every verdict printed after it is
// a claim about the INSTALLED extensions, not about the source that was
// just compiled.
//
// Scenarios:
//
//   A — Installed Build Matches This Source
//       All three extensions answer `ExtensionIdentity.current` computed
//       inside their own process; the app computes it the same way, so
//       equality is the whole test.
//
//       The asymmetry is deliberate. A stale PhantomTunnel ABORTS the
//       suite, because most of the catalogue drives it and every line
//       after would describe a binary that is not running. A stale PROXY
//       extension earns a red line and nothing more: only three entries
//       drive the proxies rather than the tunnel — the fabricated pair
//       (ExtensionGate, TunnelEdit) and the control-plane workflow, which
//       raises a real session on the two proxy extensions and never a
//       tunnel.
//
//       Silence is neither: no answer proves nothing about what is
//       installed, so it skips. One skip carries all silent extensions,
//       because `skip` holds a single slot and three calls would report
//       only the last.
//
//   B — Live Services Connected
//       One ping, so the wiring claim is earned rather than narrated.
//
//   C — Test Configs Present (Door)
//       `Test-Ghost` and `Test-WireGuard` must both be in the list. They
//       are the fuel every later workflow borrows.
//
//   D — Read Test-Ghost from vault (Ghost Expected)
//   E — Read Test-WireGuard from vault (Standalone Expected)
//       The vault answers as the app identity, and Ghost vs standalone is
//       read off the payload rather than the row. Three attempts, then a
//       skip: an unreachable vault says nothing about the config.
//
// Known blind spot, by construction: the build stamp is MARKETING_VERSION,
// so this separates BUILDS, not sources. Edit an extension, rebuild
// without moving the version, and both sides still read the same string
// while the old binary keeps running. The cure is the one
// `ExtensionIdentity` documents — move the version, or run the uninstall
// flow — and the abort message says so in the same breath as the
// diagnosis.

#if DEBUG
import Foundation

/// Proves the harness is wired end to end on the live services: the
/// three extensions are the ones this source builds, the two test
/// configs are present (the door's fuel), the vault answers as the app
/// identity, and ghost vs standalone is read correctly. No server.
///
/// It therefore touches all three daemons, not just the vault: with
/// the split or DNS extension deliberately off, the first step reports
/// their build as unknown and skips rather than failing.
///
/// A model workflow: each `steps` entry names a step method; the method
/// bodies are pure logic using the inherited helpers (log/check/fail/skip
/// and the service shortcuts). No context or reporter is threaded in.
final class SanityWorkflow: TestWorkflow {
    override var displayName: String { "Sanity Check" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Installed Build Matches This Source", installedBuildMatches),
            WorkflowStep("Live Services Connected", liveServices),
            WorkflowStep("Test Configs Present (Door)", testConfigs),
            WorkflowStep("Read Test-Ghost from vault (Ghost Expected)", readGhost),
            WorkflowStep("Read Test-WireGuard from vault (Standalone Expected)", readWireGuard),
        ]
    }

    // MARK: - Steps

    /// Attributability, and the reason it runs first: every verdict
    /// this suite prints is a claim about the INSTALLED extensions,
    /// not about the source that was just compiled. The build stamp is
    /// `MARKETING_VERSION` by design, so a rebuild under an unchanged
    /// version leaves the previously installed extensions in place
    /// (`ExtensionIdentity`'s own contract; the gate logs "identity
    /// match — activation skipped" when it happens). Without this
    /// comparison an entire green run can describe code that never
    /// reached the machine.
    ///
    /// A PROVEN mismatch ON PHANTOMTUNNEL stops the suite. Not out of
    /// severity theatre: every verdict after it would be a sentence
    /// about code that is not running, and a report full of confident
    /// claims about the wrong binary is worse than a short report. A
    /// stale PROXY extension earns a red line and nothing more — it is
    /// measured here and exercised only by the control-plane workflow at the
    /// end of this catalogue, so the run carries
    /// on; the asymmetry is argued at the branch itself. Silence is
    /// different again and does not stop anything — see below.
    ///
    /// All three probes answer `ExtensionIdentity.current` computed
    /// inside their own process, which is exactly what the app
    /// computes here — so equality is the whole test. Silence is an
    /// environment skip, not a mismatch: no answer proves nothing
    /// about what is installed.
    ///
    /// Know what this cannot see. The stamp is the marketing version,
    /// so it separates BUILDS, not sources: edit an extension, rebuild
    /// without touching the version, and both sides still read the
    /// same string while the old binary keeps running. That case is
    /// invisible here by construction, and the only cure is the one
    /// `ExtensionIdentity` documents — move the version, or run the
    /// uninstall flow, so the installed extension is actually
    /// replaced. What this step does catch is the version-to-version
    /// case, which is exactly when a stale install is most likely and
    /// most misleading.
    func installedBuildMatches() async {
        let expected = ExtensionIdentity.current
        // The stamp reads `?` when the app's own Info.plist has no
        // short version string. Both sides compute it the same way, so
        // `?` == `?` would sail through green while proving nothing —
        // the one comparison this step must refuse to make.
        guard expected != "?" else {
            fail("the app itself has no build stamp (CFBundleShortVersionString missing) — nothing can be attributed this run")
            return
        }
        log("app build stamp: \(expected)")

        var unknown: [String] = []
        var stale: [String] = []

        switch await vault.ping() {
        case .ready(_, let identity), .doorFailed(let identity):
            if !check(identity == expected, "PhantomTunnel installed=\(identity)") {
                stale.append("PhantomTunnel(\(identity))")
            }
        case .unreachable:
            log("PhantomTunnel: vault unreachable, build unknown", .warn)
            unknown.append("PhantomTunnel")
        }

        if let identity = await splitClient.identity() {
            if !check(identity == expected, "PhantomSplitTunnel installed=\(identity)") {
                stale.append("PhantomSplitTunnel(\(identity))")
            }
        } else {
            log("PhantomSplitTunnel: daemon silent, build unknown", .warn)
            unknown.append("PhantomSplitTunnel")
        }

        if let identity = await dnsClient.identity() {
            if !check(identity == expected, "PhantomDNSProxy installed=\(identity)") {
                stale.append("PhantomDNSProxy(\(identity))")
            }
        } else {
            log("PhantomDNSProxy: daemon silent, build unknown", .warn)
            unknown.append("PhantomDNSProxy")
        }

        // Only a stale PhantomTunnel stops the suite, and the asymmetry
        // is the point: every workflow that drives a real session or the
        // real vault drives the tunnel extension — all but the fabricated
        // pair TestCatalog names (ExtensionGate, TunnelEdit) — so a stale
        // one makes most of the report a statement about code that is not
        // running. The proxy extensions are measured here and driven only
        // by the last workflow in this catalogue, so
        // a stale one is worth a red line and nothing more — aborting
        // on it would let an untouched neighbour cancel a run that was
        // never about it. A rebuild alone fixes neither: the stamp
        // is MARKETING_VERSION, so an unchanged version reinstalls
        // nothing. Say the cure in the same breath as the diagnosis.
        let staleTunnel = stale.filter { $0.hasPrefix("PhantomTunnel") }
        if !staleTunnel.isEmpty {
            abortRun("PhantomTunnel is from another build — \(staleTunnel.joined(separator: ", ")) vs expected \(expected); every step below drives it, so nothing here would mean anything. Bump the version or run the uninstall flow, then rerun")
        } else if !stale.isEmpty {
            log("stale proxy extension(s): \(stale.joined(separator: ", ")) — measured; only the control-plane workflow at the end of this catalogue drives them, so the run continues", .error)
        }

        // One reason for all of them: `skip` holds a single slot, so
        // three separate calls would report only the last silent
        // extension and quietly drop the other two.
        if !unknown.isEmpty {
            skip("environment: no answer from \(unknown.joined(separator: ", "))")
        }
    }

    func liveServices() async {
        log("TunnelsManager: \(tunnels.tunnels.count) tunnels visible")
        // The wiring claim must be earned, not narrated: one ping
        // proves the vault client answers end-to-end. Before this,
        // the step carried no check at all and could never be
        // anything but PASS.
        switch await vault.ping() {
        case .ready(let payloads, let identity):
            check(true, "vault answers from @Environment — identity=\(identity) payloads=\(payloads)")
        case .doorFailed(let identity):
            fail("vault door failed — identity=\(identity)")
        case .unreachable:
            skip("environment: vault unreachable")
        }
    }

    func testConfigs() async {
        check(tunnel(named: TestContext.ghostName) != nil,
              "\(TestContext.ghostName): \(tunnel(named: TestContext.ghostName) != nil ? "present" : "absent")")
        check(tunnel(named: TestContext.wireGuardName) != nil,
              "\(TestContext.wireGuardName): \(tunnel(named: TestContext.wireGuardName) != nil ? "present" : "absent")")
    }

    func readGhost() async { await read(TestContext.ghostName, expectGhost: true) }
    func readWireGuard() async { await read(TestContext.wireGuardName, expectGhost: false) }

    // MARK: - Shared

    private func read(_ name: String, expectGhost: Bool) async {
        guard let container = tunnel(named: name) else {
            fail("\(name): not found")
            return
        }
        for attempt in 1...3 {
            switch await vault.read(id: container.id) {
            case .config(let cfg):
                check(cfg.isGhostMode == expectGhost,
                      "vault: config read — isGhostMode=\(cfg.isGhostMode) (expected \(expectGhost))")
                return
            case .missing:
                fail("vault: missing")
                return
            case .undecodable:
                fail("vault: undecodable payload for a door config")
                return
            case .unreachable:
                log("vault: unreachable (attempt \(attempt)/3)", .warn)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        // Same doctrine as the first step: no answer proves nothing
        // about the config under test, and this step's claim is about
        // the config, not about the transport.
        skip("environment: vault unreachable after 3 attempts")
    }
}
#endif
