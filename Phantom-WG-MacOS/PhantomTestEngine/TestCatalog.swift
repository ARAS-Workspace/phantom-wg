#if DEBUG
import Foundation

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
            TunnelEditWorkflow(),
            SplitControlPlaneWorkflow(),
        ]
    }
}
#endif
