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
// Split Control Plane (App ↔ Extensions)
//
// Drives a REAL split-tunnelling session and measures whether the app and
// BOTH proxy extensions agree at every step. The witness is each
// extension's OWN ring buffer, drained over its own XPC channel — the
// app's log could only report what the app believes.
//
// Topology:
//
//     ┌─────────────┐   XPC    ┌────────────────────┐
//     │     app     │─────────→│ PhantomSplitTunnel │
//     │ coordinator │   XPC    ├────────────────────┤
//     │             │─────────→│   PhantomDNSProxy  │
//     └──────┬──────┘          └────────────────────┘
//            │ NE preferences
//     ┌──────┴──────┐
//     │   system    │
//     └─────────────┘
//
// It runs LAST in the catalogue because it raises a real proxy session.
//
// Scenarios:
//
//   A — Split-Tunneling Is Off (Door)
//       The feature must be at rest on three readings — persisted intent,
//       coordinator state, session status — plus the extension gate. The
//       skip NAMES whichever one spoke: an unattributable skip is one this
//       suite cannot act on. Skipped rather than driven anyway, because
//       taking over a live session would stop the user's own
//       split-tunnelling to measure it.
//
//   B — A Start Reaches Both Extensions
//       Session raised. No buffer claim here: the receipt belongs to C,
//       where the provider actually writes one.
//
//   C — A Live Edit Lands On Both
//       The claim the corridor was built for. `reconfigure` answers a
//       typed verdict per extension, and the PROVIDER's own log line is
//       the stronger reading — the daemon answers `true` both when it
//       APPLIES a payload and when it BUFFERS one, so a verdict alone
//       cannot tell delivery from storage. DNSProxy is registered-but-lazy
//       by design, so an empty buffer there skips rather than fails.
//
//   D — A Boot Realigns The Session It Adopts
//   E — Two Transitions Queue Rather Than Interleave
//       Read from the chain's own high-water mark, not sampled: a 20ms
//       sampler measured zero against a chain that was demonstrably
//       serializing.
//   F — A Stop Lands And An Edit After It Says So
//       The user's own bootstrap blob goes back BEFORE the stop, which is
//       the only moment `persistConfiguration` can still write.
//
// The probe entries carry signing identifiers no process on any machine
// holds, so nothing can match them and no traffic changes lanes — but they
// are still ENTRIES, so the provider's diff logger has something to write.

#if DEBUG
import Foundation

@MainActor
final class SplitControlPlaneWorkflow: TestWorkflow {

    override var displayName: String { "Split Control Plane (App ↔ Extensions)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Split-Tunneling Is Off (Door)", door),
            WorkflowStep("A Start Reaches Both Extensions", startReachesBoth),
            WorkflowStep("A Live Edit Lands On Both", liveEditLandsOnBoth),
            WorkflowStep("A Boot Realigns The Session It Adopts", bootRealigns),
            WorkflowStep("Two Transitions Queue Rather Than Interleave", transitionsQueue),
            WorkflowStep("A Stop Lands And An Edit After It Says So", stopThenEdit),
        ]
    }

    // MARK: - Door

    private var doorOpen = false

    private var userConfig: SplitTunnelingConfiguration?

    private func door() async {
        await splitManager.load()
        await dnsManager.load()

        let intent = splitStore.configuration.isEnabled
        let state = split.state
        let session = splitManager.sessionStatus
        log("persisted intent isEnabled=\(intent), coordinator state=\(state), session=\(session)")

        var speaking: [String] = []
        if intent { speaking.append("the persisted intent") }
        if state != .stopped { speaking.append("the coordinator (state=\(state))") }
        if session != .disconnected { speaking.append("the session (status=\(session))") }

        guard speaking.isEmpty else {
            skip("environment: split-tunneling is in use — "
                 + speaking.joined(separator: " and ")
                 + " would have to be taken over to measure it")
            return
        }
        guard gate.allReady else {
            skip("environment: the extension gate is not ready, so a start would be measuring approval rather than the control plane")
            return
        }

        userConfig = splitStore.configuration
        doorOpen = true
        check(true, "the feature is at rest on all three readings, so this run can drive it and give it back")

        onTeardown("split control plane") { [weak self] in
            guard let self, self.doorOpen else { return }
            if let userConfig, self.split.state == .running {
                try? await self.splitManager.persistConfiguration(userConfig)
                self.log("teardown: the user's own configuration is back in the bootstrap blob")
            }
            await self.split.stop()
            self.log("teardown: split-tunneling left \(self.split.state), session=\(self.splitManager.sessionStatus)")
        }
    }

    // MARK: - Steps

    private func startReachesBoth() async {
        guard doorOpen else { return skip("the door found the feature in use") }

        await clearBothBuffers()
        do {
            try await split.start(with: startConfig)
        } catch {
            fail("the start did not complete — \(error.localizedDescription)")
            return
        }
        check(split.state == .running, "the coordinator is running — state=\(split.state)")
        let raised = await settle(within: 10) {
            self.splitManager.sessionStatus == .connected || self.splitManager.sessionStatus == .connecting
        }
        check(raised, "and the system raised the proxy session — status=\(splitManager.sessionStatus)")

        log("session raised; the receipt is measured by the edit step, which is where the provider writes one")
    }

    private func liveEditLandsOnBoth() async {
        guard doorOpen else { return skip("the door found the feature in use") }
        guard split.state == .running else { return skip("no running session — the start step owns that") }

        await clearBothBuffers()
        let outcome = await split.reconfigure(with: probeConfig)
        guard case .pushed(let splitPush, let dnsPush) = outcome else {
            fail("a reconfigure on a running session reported \(outcome) rather than pushing")
            return
        }
        check(splitPush == .done, "SplitTunnel accepted the push — \(splitPush.label)")
        check(dnsPush == .done, "DNSProxy accepted the push — \(dnsPush.label)")
        check(outcome.bothLanded, "so both landed, which is the only reading that counts as delivered")

        let splitLog = await splitClient.fetchLogs() ?? ""
        check(splitLog.contains(Self.probeSigningIDB),
              "and PhantomSplitTunnel's PROVIDER logged the entry it took, which is what tells applied apart from buffered")

        let dnsLog = await dnsClient.fetchLogs() ?? ""
        if dnsLog.isEmpty {
            skip("environment: DNSProxy has not been spawned yet (registered-but-lazy), so it has no provider to write a receipt")
        } else {
            check(dnsLog.contains(Self.probeSigningIDB),
                  "and PhantomDNSProxy's PROVIDER logged it too, so both halves are proven rather than one assumed")
        }
    }

    private func bootRealigns() async {
        guard doorOpen else { return skip("the door found the feature in use") }
        guard split.state == .running else { return skip("no running session — the start step owns that") }

        let outcome = await split.boot { self.probeConfig }
        guard case .pushed(let splitPush, let dnsPush) = outcome else {
            fail("boot adopted a live session but reported \(outcome) — the realign is what keeps a respawned extension from serving a stale list")
            return
        }
        check(splitPush == .done && dnsPush == .done,
              "the realign reached both extensions — SplitTunnel \(splitPush.label), DNSProxy \(dnsPush.label)")
        check(split.state == .running,
              "and the adopted state is still running, written after the pushes rather than before them")
    }

    private func transitionsQueue() async {
        guard doorOpen else { return skip("the door found the feature in use") }
        guard split.state == .running else { return skip("no running session — the start step owns that") }

        let depthBefore = split.maxChainDepth
        async let first = split.reconfigure(with: probeConfig)
        async let second = split.reconfigure(with: probeConfig)
        let results = await [first, second]

        check(split.maxChainDepth > depthBefore,
              "the chain held two links at once rather than admitting both — depth \(depthBefore) → \(split.maxChainDepth)")
        check(results.allSatisfy { $0.bothLanded },
              "and neither push was lost to the other — \(results.map { String(describing: $0) }.joined(separator: ", "))")
    }

    private func stopThenEdit() async {
        guard doorOpen else { return skip("the door found the feature in use") }
        guard split.state == .running else { return skip("no running session — the start step owns that") }

        if let userConfig {
            do {
                try await splitManager.persistConfiguration(userConfig)
                log("the user's own configuration is back in the bootstrap blob")
            } catch {
                log("the user's configuration could NOT be put back: \(error.localizedDescription)", .warn)
            }
        }

        await split.stop()
        check(split.state == .stopped, "the coordinator reports stopped — state=\(split.state)")
        let settled = await settle(within: 10) { self.splitManager.sessionStatus == .disconnected }
        check(settled, "and the system took the session down — status=\(splitManager.sessionStatus)")

        let outcome = await split.reconfigure(with: probeConfig)
        check(outcome == .notRunning,
              "and an edit after it reports notRunning rather than claiming a push — \(outcome)")
    }

    // MARK: - Shared

    private static let probeSigningIDA = "com.remrearas.phantom-wg.test-engine.no-such-process.a"
    private static let probeSigningIDB = "com.remrearas.phantom-wg.test-engine.no-such-process.b"

    private func probeEntry(_ id: String) -> AppEntry {
        AppEntry(signingIdentifier: id, bundleIdentifier: id, displayName: "PhantomTestEngine probe")
    }

    private var startConfig: SplitTunnelingConfiguration {
        SplitTunnelingConfiguration(
            isEnabled: true, interfaceSelection: .auto,
            apps: [probeEntry(Self.probeSigningIDA)]
        )
    }

    private var probeConfig: SplitTunnelingConfiguration {
        SplitTunnelingConfiguration(
            isEnabled: true, interfaceSelection: .auto,
            apps: [probeEntry(Self.probeSigningIDA), probeEntry(Self.probeSigningIDB)]
        )
    }

    private func clearBothBuffers() async {
        _ = await splitClient.clearLogs()
        _ = await dnsClient.clearLogs()
    }
}
#endif
