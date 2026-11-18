// Test Engine: Workflow Catalogue
//
// The ordered list a run executes, top to bottom. Order is part of the
// arrangement rather than presentation: `SanityWorkflow` measures the
// environment before anything drives it.
//
// A workflow reaches a run only by appearing here.

#if DEBUG
import Foundation

@MainActor
enum TestCatalog {
    static var workflows: [TestWorkflow] {
        [
            SanityWorkflow(),
            ConfigContractWorkflow(),
            TunnelAddWorkflow(),
            TunnelEditWorkflow(),
            TunnelRemoveWorkflow(),
            TunnelLoadWorkflow()
        ]
    }
}
#endif
