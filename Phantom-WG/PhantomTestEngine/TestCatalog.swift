// Test Engine: Workflow Catalogue
//
// The ordered list a run executes, top to bottom. Order is part of the
// arrangement rather than presentation: `SanityWorkflow` measures the
// environment before anything drives it.
//
// A workflow reaches a run only by appearing here. A run asked for by
// family name (`selection(_:)`) takes its workflows from this list and
// keeps its order.

#if DEBUG
import Foundation

@MainActor
enum TestCatalog {
    static var workflows: [TestWorkflow] {
        [
            SanityWorkflow(),
            ConfigContractWorkflow(),
            ArchiveNamesWorkflow(),
            TunnelTransferWorkflow(),
            TunnelListWorkflow(),
            TunnelBulkDeleteWorkflow(),
            TunnelAddWorkflow(),
            TunnelEditWorkflow(),
            TunnelRemoveWorkflow(),
            ActivationSeamWorkflow(),
            PrivateDataWorkflow(),
            LogsWorkflow(),
            TunnelLoadWorkflow(),
            PhantomTunnelWorkflow(.standalone),
            PhantomTunnelWorkflow(.ghost),
            UnreachableWorkflow(),
            RecoverySwitchWorkflow()
        ]
    }

    /// The workflows of the families `names` holds, in catalogue order,
    /// and the names that are no family's.
    static func selection(_ names: [String]) -> (workflows: [TestWorkflow], unknown: [String]) {
        let all = workflows
        let known = Set(all.map(\.family))
        return (all.filter { names.contains($0.family) }, names.filter { !known.contains($0) })
    }
}
#endif
