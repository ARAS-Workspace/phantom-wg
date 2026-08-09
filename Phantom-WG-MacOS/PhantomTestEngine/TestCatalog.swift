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
            // ← register new workflows here
        ]
    }
}
#endif
