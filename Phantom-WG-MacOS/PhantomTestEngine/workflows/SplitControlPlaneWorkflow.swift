#if DEBUG
import Foundation

/// The app↔extension control plane, driven on the REAL surface.
///
/// No fakes here, and that is a deliberate difference from every other
/// workflow that drives a lifecycle. The proxy managers and both daemon
/// clients are the user's own, because what this run measures is
/// precisely whether configuration the app accepts REACHES two
/// independently spawned extensions — a claim no synthetic provider can
/// carry. The system's approval prompt is a one-time install concern,
/// not a per-run one: once both proxies are approved and visible in
/// System Settings, `saveToPreferences` and `startVPNTunnel` no longer
/// ask.
///
/// Two narrowings keep that safe.
///
/// The configurations pushed here list only signing identifiers that no
/// process on any machine carries, so `FlowDecisionEngine` can never
/// match one and no application's traffic changes lanes. That claim is
/// narrower than it first reads and the difference is stated rather than
/// implied: raising a DNS proxy session puts the machine's DNS through
/// the extension's relay whatever the list says, and unmatched queries
/// go on to the system resolver unpinned. What the list buys is that no
/// APP is bypassed — not that the extension sits idle.
///
/// The coordinator's API is config-in, so a run drives it without
/// consulting `SplitTunnelingStore` for any decision; the user's own
/// configuration is read once, to put it back.
///
/// And it goes LAST in the catalog, after the two fabricated workflows
/// that used to be the tail. Those touch neither the real vault nor the
/// system's preferences; this one touches preferences by design, so
/// nothing that runs after it could be trusted to be undisturbed.
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

    /// Whether the door found the feature at rest. Every step below
    /// reads it, because a skipped door must not be followed by five
    /// steps driving a session the user owns.
    private var doorOpen = false

    /// The configuration the user actually has, captured before
    /// anything is driven so the teardown can put their own bootstrap
    /// blob back.
    private var userConfig: SplitTunnelingConfiguration?

    /// The feature must be OFF, and "off" is three readings rather than
    /// one — this corridor exists because they diverge. The persisted
    /// intent, the coordinator's session state and the manager's own
    /// `NEVPNStatus` each get asked, and the skip NAMES whichever one
    /// spoke: an unattributable skip is the kind this suite reads out
    /// loud and cannot act on.
    ///
    /// Skipped rather than failed, and rather than driven anyway. A run
    /// that took over a live session would stop the user's own
    /// split-tunneling to measure it, which is a cost no green line
    /// pays back.
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
        // A fourth reading the first version skipped, and the run
        // itself proved why: a boot right after a redeploy failed with
        // `NEConfigurationErrorDomain Code=10 permission denied`, the
        // proxy configurations not yet approved for the fresh
        // registration. Driving a start into that measures approval, not
        // the control plane — and it would leave preference entries this
        // run has no arm to delete.
        guard gate.allReady else {
            skip("environment: the extension gate is not ready, so a start would be measuring approval rather than the control plane")
            return
        }

        userConfig = splitStore.configuration
        doorOpen = true
        check(true, "the feature is at rest on all three readings, so this run can drive it and give it back")

        onTeardown("split control plane") { [weak self] in
            guard let self, self.doorOpen else { return }
            // The net for an ABORTED run, not the normal path — the last
            // step restores and stops on its own. This arm fires only
            // when the run never reached it and the session is therefore
            // still up, which is the one case where
            // `persistConfiguration` can still write.
            if let userConfig, self.split.state == .running {
                try? await self.splitManager.persistConfiguration(userConfig)
                self.log("teardown: the user's own configuration is back in the bootstrap blob")
            }
            await self.split.stop()
            self.log("teardown: split-tunneling left \(self.split.state), session=\(self.splitManager.sessionStatus)")
        }
    }

    // MARK: - Steps

    /// A start has to do more than return: both extensions have to be
    /// holding the configuration afterwards. The witness is each
    /// extension's OWN ring buffer, drained over its own XPC channel —
    /// the app's log could only report what the app believes.
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
        // Polled, not read once. `sessionStatus` is written by the
        // NEVPNStatusDidChange observer, so the value the instant
        // `startVPNTunnel()` returns is still the old one — the first
        // version of this check read `.disconnected` off a session that
        // came up milliseconds later and called that a failure.
        let raised = await settle(within: 10) {
            self.splitManager.sessionStatus == .connected || self.splitManager.sessionStatus == .connecting
        }
        check(raised, "and the system raised the proxy session — status=\(splitManager.sessionStatus)")

        // No buffer claim here. `fetchLogs` returns the extension's RING
        // BUFFER while the daemon's own lines go to `os_log`, so an
        // assertion on it would be reading the wrong sink — which is
        // what the first version of this step did. The receipt belongs
        // to the edit step below, where the provider writes one.
        log("session raised; the receipt is measured by the edit step, which is where the provider writes one")
    }

    /// The claim the whole corridor was built for: an edit made while
    /// the feature runs reaches BOTH extensions, and the app can say
    /// which one did not. `reconfigure` answers a typed verdict per
    /// extension now, so this reads the answer rather than a log line.
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

        // The receipt, and it is stronger than the verdict above: the
        // daemon answers `true` both when it APPLIES a payload and when
        // it BUFFERS one for a provider that has not spawned, so `done`
        // alone cannot tell delivery from storage. `logAppDiff` runs
        // inside the PROVIDER's `applyConfiguration`, so a line carrying
        // the entry is the provider itself saying it took the list.
        //
        // Which is why the payload carries one entry rather than none:
        // `logAppDiff` writes only what CHANGED, so an empty list pushed
        // over an empty list is a receipt that can never be written —
        // the first version of this step asked for one and failed itself
        // on a narrowing it had chosen two screens earlier.
        let splitLog = await splitClient.fetchLogs() ?? ""
        check(splitLog.contains(Self.probeSigningIDB),
              "and PhantomSplitTunnel's PROVIDER logged the entry it took, which is what tells applied apart from buffered")

        // The same reading for the DNS half, and it was missing: a
        // `.done` from that daemon means applied OR buffered, so the
        // step proved delivery on one side and ASSUMED it on the other.
        // Skipped rather than failed when the buffer is empty, because
        // DNSProxy is registered-but-lazy by design (ADR-0003 item 3) —
        // with no port-53 flow yet no provider has spawned, so there is
        // nothing that COULD have logged.
        let dnsLog = await dnsClient.fetchLogs() ?? ""
        if dnsLog.isEmpty {
            skip("environment: DNSProxy has not been spawned yet (registered-but-lazy), so it has no provider to write a receipt")
        } else {
            check(dnsLog.contains(Self.probeSigningIDB),
                  "and PhantomDNSProxy's PROVIDER logged it too, so both halves are proven rather than one assumed")
        }
    }

    /// `boot` adopting a live session used to push nothing, so an
    /// extension that respawned since the last start kept serving the
    /// list it booted with and nothing repaired it. Driven here against
    /// the session the start above raised.
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

    /// Serialization, observed rather than argued. `queuedLinks` is the
    /// fact the chain publishes: a link that has not run a line of its
    /// operation yet is waiting, and `state` cannot say so because
    /// nothing has moved.
    private func transitionsQueue() async {
        guard doorOpen else { return skip("the door found the feature in use") }
        guard split.state == .running else { return skip("no running session — the start step owns that") }

        let depthBefore = split.maxChainDepth
        // Two pushes dispatched in one turn. Serialized, the second
        // waits; interleaved, both would be inside the coordinator at
        // once over the same two daemon channels.
        async let first = split.reconfigure(with: probeConfig)
        async let second = split.reconfigure(with: probeConfig)
        let results = await [first, second]

        // Read from the chain's OWN high-water mark rather than sampled.
        // The first version polled `queuedLinks` every 20ms and measured
        // zero against a chain that WAS serializing — the run's own log
        // shows the second reconfigure starting only after the first had
        // finished — so the step failed on its sampling rate and
        // reported that the product had not queued.
        check(split.maxChainDepth > depthBefore,
              "the chain held two links at once rather than admitting both — depth \(depthBefore) → \(split.maxChainDepth)")
        check(results.allSatisfy { $0.bothLanded },
              "and neither push was lost to the other — \(results.map { String(describing: $0) }.joined(separator: ", "))")
    }

    /// The stop, and the reading that follows it. An edit after a stop
    /// reports `.notRunning` rather than a failure: the payload is on
    /// disk and the next start carries it, which is a fact worth
    /// reporting and not an error to hide.
    private func stopThenEdit() async {
        guard doorOpen else { return skip("the door found the feature in use") }
        guard split.state == .running else { return skip("no running session — the start step owns that") }

        // The blob goes back BEFORE the stop, and this is the only
        // place it can: `persistConfiguration` reads `isEnabled` off
        // disk and refuses a disabled entry, so once the stop lands
        // there is no writing left to do. The first version left this to
        // the teardown, which runs AFTER this step — so on the green
        // path the restore arm was unreachable and the probe entries
        // stayed in the user's preference store under a log line
        // claiming they had been handed back.
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
        // Read from the SYSTEM, not from the enum the line above wrote.
        // `performStop` writes `.stopped` on the arm that actually asks
        // — including when a disable was refused — so the check above
        // states the coordinator's intent; this one states the machine's.
        // (The already-stopped arm returns without touching `state` at
        // all, which is why "every path" was the wrong word.)
        //
        // `stop()` also hands back a `StopOutcome` naming anything that
        // stayed registered, and this step deliberately does not assert
        // on it: nothing in this run can make a disable fail, so such a
        // check could not go red and would only look like proof. The
        // gap is real and recorded rather than papered over — a refused
        // stop has no witness anywhere.
        let settled = await settle(within: 10) { self.splitManager.sessionStatus == .disconnected }
        check(settled, "and the system took the session down — status=\(splitManager.sessionStatus)")

        let outcome = await split.reconfigure(with: probeConfig)
        check(outcome == .notRunning,
              "and an edit after it reports notRunning rather than claiming a push — \(outcome)")
    }

    // MARK: - Shared

    /// Two signing identifiers no process on any machine carries.
    ///
    /// They keep a real session safe to raise AND leave a receipt to
    /// read. `FlowDecisionEngine` matches flows by signing identifier,
    /// so neither can ever match one and no traffic changes lanes; but
    /// they are still ENTRIES, so the provider's `logAppDiff` writes a
    /// line when the list between two pushes CHANGES.
    ///
    /// Two of them rather than one, because that helper logs only the
    /// difference and the first two versions of this step each handed it
    /// none. The first pushed an empty list over an empty list. The
    /// second pushed ONE entry, but `start` had already written that
    /// same entry into the bootstrap blob, so the provider read it at
    /// `startProxy` and the later push was identical to what it already
    /// held — the same mistake one layer up, and the same green-looking
    /// nothing in the buffer. The start carries A; the edit carries A
    /// and B, so what the provider logs is the arrival of B.
    private static let probeSigningIDA = "com.remrearas.phantom-wg.test-engine.no-such-process.a"
    private static let probeSigningIDB = "com.remrearas.phantom-wg.test-engine.no-such-process.b"

    private func probeEntry(_ id: String) -> AppEntry {
        AppEntry(signingIdentifier: id, bundleIdentifier: id, displayName: "PhantomTestEngine probe")
    }

    /// What `start` raises the session with.
    private var startConfig: SplitTunnelingConfiguration {
        SplitTunnelingConfiguration(
            isEnabled: true, interfaceSelection: .auto,
            apps: [probeEntry(Self.probeSigningIDA)]
        )
    }

    /// What every push after the start carries: the start's entry plus
    /// one more, so the provider has a diff to write.
    ///
    /// One claim is still not witnessed here and is named rather than
    /// implied: pushes after the first carry the same bytes as each
    /// other, so `persistConfiguration`'s differ-check skips its write
    /// and nothing below measures that write.
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
