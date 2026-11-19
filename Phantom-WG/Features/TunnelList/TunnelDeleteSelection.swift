import Foundation
import Observation

/// The delete selection's state, shared by its rows (`TunnelDeleteSection`)
/// and its bottom bar (`TunnelDeleteBar`): the marked rows, the
/// confirmation the bar asks for, and how far a running delete has come.
@MainActor
@Observable
final class TunnelDeleteSelection {

    /// How far a delete has run: the targets done out of every target.
    struct Progress: Equatable {
        let done: Int
        let total: Int
    }

    var marked: Set<UUID> = []
    var confirming = false
    var running = false
    var progress: Progress?
}
