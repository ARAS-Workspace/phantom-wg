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
/// The configurations pushed here carry an EMPTY app list. The
/// coordinator's API is config-in, so a run can drive it without
/// touching `SplitTunnelingStore` — the user's own list and file are
/// never read for a decision and never written. An empty list also
/// means the sessions this run raises bypass nothing at all, so no
/// traffic changes lanes while it runs.
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

    /// Highest `queuedLinks` the serialization step sampled. A property
    /// rather than a local, so the sampler task and the step read one
    /// place under the same actor.
    private var queuePeak = 0

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
        guard gate.allReady else {
            skip("environment: the extension gate is not ready, so a start would be measuring approval rather than the control plane")
            return
        }

        userConfig = splitStore.configuration
        doorOpen = true
        check(true, "the feature is at rest on all three readings, so this run can drive it and give it back")

        onTeardown("split control plane") { [weak self] in
            guard let self, self.doorOpen else { return }
            // The user's own list goes back into the bootstrap blob
            // BEFORE the stop, not after: `persistConfiguration` reads
            // `isEnabled` off disk and refuses a disabled entry, so
            // once the stop lands there is no writing left to do.
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
            try await split.start(with: probeConfig)
        } catch {
            fail("the start did not complete — \(error.localizedDescription)")
            return
        }
        check(split.state == .running, "the coordinator is running — state=\(split.state)")
        check(splitManager.sessionStatus == .connected || splitManager.sessionStatus == .connecting,
              "and the system raised the proxy session — status=\(splitManager.sessionStatus)")

        // DNSProxy is registered-but-lazy by design (ADR-0003 item 3):
        // the OS spawns it on the first port-53 flow, so its buffer may
        // legitimately be silent here. Its receipt is proven by the
        // edit step below, which pushes over XPC and wakes it.
        let splitLog = await splitClient.fetchLogs()
        check(splitLog?.isEmpty == false,
              "PhantomSplitTunnel is alive and answering its own channel — \(splitLog?.count ?? 0) bytes of its buffer came back")
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

        // The receipt, from the extension's own mouth. `applyConfig`
        // logs the apply on the daemon side, so a buffer that carries
        // it is the extension saying it took the payload.
        let splitLog = await splitClient.fetchLogs() ?? ""
        check(splitLog.contains("applyConfig"),
              "and PhantomSplitTunnel's own buffer records the RPC it answered")
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

        queuePeak = 0
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                self.queuePeak = max(self.queuePeak, self.split.queuedLinks)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        // Two pushes dispatched in one turn. Serialized, the second
        // waits; interleaved, both would be inside the coordinator at
        // once over the same two daemon channels.
        async let first = split.reconfigure(with: probeConfig)
        async let second = split.reconfigure(with: probeConfig)
        let results = await [first, second]
        sampler.cancel()

        check(queuePeak >= 1, "the chain queued rather than admitting both at once — queued peak=\(queuePeak)")
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

        await split.stop()
        check(split.state == .stopped, "the stop landed — state=\(split.state)")

        let outcome = await split.reconfigure(with: probeConfig)
        check(outcome == .notRunning,
              "and an edit after it reports notRunning rather than claiming a push — \(outcome)")
    }

    // MARK: - Shared

    /// The payload this run drives with: enabled, automatic interface,
    /// and NO apps.
    ///
    /// The empty list is what makes raising a real session safe — it
    /// bypasses nothing, so no traffic moves lanes while the control
    /// plane is measured. It is also why every push here carries the
    /// SAME bytes, and that costs one claim honestly: with the blob
    /// unchanged, `persistConfiguration`'s differ-check skips its write,
    /// so nothing below witnesses that write. What is measured is the
    /// XPC delivery, which runs on every push regardless. Varying the
    /// payload would mean listing an app or pinning an interface, and
    /// both change what the running proxy does to real traffic.
    private var probeConfig: SplitTunnelingConfiguration {
        SplitTunnelingConfiguration(isEnabled: true, interfaceSelection: .auto, apps: [])
    }

    private func clearBothBuffers() async {
        _ = await splitClient.clearLogs()
        _ = await dnsClient.clearLogs()
    }
}
#endif
