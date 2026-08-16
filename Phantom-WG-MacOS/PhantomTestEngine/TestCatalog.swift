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
            // Fabricated end of the list: this one and the gate above
            // touch neither the real vault nor the system's
            // preferences, so their position cannot perturb a pass that
            // does — and nothing they leave can reach one, because they
            // leave nothing.
            TunnelEditWorkflow(),
            // ← register new workflows here
        ]
    }
}
#endif
