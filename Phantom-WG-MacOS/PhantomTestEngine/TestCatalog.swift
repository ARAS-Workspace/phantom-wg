#if DEBUG
import Foundation

/// The single place workflows are registered. Add one from
/// `PhantomTestEngine/workflows/` here — one line, plug and play. There
/// is no discovery: the list is explicit and ordered on purpose.
@MainActor
enum TestCatalog {
    static var workflows: [TestWorkflow] {
        [
            SanityWorkflow(),
            VaultIntegrityWorkflow(),
            IsolationWorkflow(),
            ActivationSeamWorkflow(),
            ConfigContractWorkflow(),
            PhantomTunnelWorkflow(.standalone),
            PhantomTunnelWorkflow(.ghost),
            RecoverySwitchWorkflow(),
            UnreachableWorkflow(),
            ExtensionGateWorkflow(),
            // Fabricated PAIR, no longer the end of the list: this one
            // and the gate above
            // touch neither the real vault nor the system's
            // preferences, so their position cannot perturb a pass that
            // does — and nothing they leave can reach one, because they
            // leave nothing.
            TunnelEditWorkflow(),
            // And the real end of the list, for the opposite reason to
            // the two above: this one drives the system's PREFERENCES
            // on purpose — it raises an actual proxy session to measure
            // whether configuration reaches two independently spawned
            // extensions. Nothing may run after it and still claim to
            // have found the machine undisturbed. It gives the feature
            // back in its teardown, and it refuses to run at all when
            // the user already has split-tunneling in use.
            // ← register new workflows here, ABOVE the one below: it
            // has to stay last.
            SplitControlPlaneWorkflow(),
        ]
    }
}
#endif
