import Foundation

/// Opcode `3`'s reply, on the wire.
///
/// The app↔extension provider-message channel is a byte protocol: the
/// first byte of the request is the opcode, and until now every reply
/// echoed that opcode back and said nothing else. Opcode 3 asks the
/// extension to rebuild its tunnel layer in place, and its four exits
/// — nothing to rebuild, wstunnel refused to come back, the adapter
/// refused to come back, and a clean rebuild — all left the same
/// single byte behind. So a caller could not tell a layer that came
/// back from one that stayed down, and nothing in the app ever tried:
/// the reply was discarded at the only site that read it.
///
/// The reply now carries a SECOND byte, and this type is what both
/// sides read it as. The extension is the only writer; the app and
/// the preview surface are the readers.
///
/// WIRE SHAPE — `[3, status]`, where status is a `RawValue` below.
/// The first byte is unchanged, deliberately: extending a message is
/// only safe while the meaning already on the wire keeps its meaning,
/// and `3` still means "this is the answer to your reset".
///
/// COMPATIBILITY, and why an ABSENT outcome is not a failure: a
/// one-byte reply is what every build before this one sent, and it
/// meant "the call completed" — the only thing the app could
/// conclude. A reader that turned the missing byte into an error
/// would be inventing a failure out of an older extension's silence,
/// which is the exact mistake this whole channel is being audited
/// for. So absence is modelled as `nil` from `read(_:)` rather than
/// as a case of this enum — there are four cases and every one of
/// them is a thing the extension SAID — and the app treats `nil` as
/// it treated any reply before the byte existed. This matters for a
/// window narrower than it looks: app and extension ship together,
/// but the extension the system is running is the one approved
/// before the update, so the pair is mismatched for exactly as long
/// as it takes the new extension to be activated.
///
/// Nothing logs that window. `resetConnection(of:)` returns silently
/// on `nil`, and the sentences that name an absent byte live in the
/// suite, against a fake that can produce one. A field reader
/// looking for a mismatched pair has the suite's account and this
/// note, not a live line — said here rather than promised.
enum TunnelResetReply: UInt8, Sendable {
    /// The layer was torn down and built back up. The WireGuard
    /// handshake may still be settling — this says the rebuild
    /// finished, not that the peer has answered since.
    case rebuilt = 0

    /// Nothing was rebuilt, because there was no live layer config to
    /// rebuild from. Not a failure of the reset: the extension was
    /// asked to restart something it is not running.
    case skipped = 1

    /// wstunnel would not start again. Ghost mode only. The layer is
    /// down and `utun` is still up, so nothing leaks — but nothing
    /// flows either, and the user's next move decides.
    case wstunnelFailed = 2

    /// The WireGuard adapter would not start again. The layer is down
    /// under a `utun` that is still up. Same containment, same
    /// consequence for the user as `wstunnelFailed`; they stay apart
    /// because they point at different halves of the stack and the
    /// logs to read next are different.
    case adapterFailed = 3

    /// Whether the caller has a rebuilt layer on the other side of
    /// this reply. Written as a property rather than left to each
    /// call site's `== .rebuilt`, so a case added later has to be
    /// answered here instead of quietly joining the success side.
    var isRebuilt: Bool { self == .rebuilt }

    /// What the reply bytes say, or `nil` when they do not say
    /// anything — a missing reply, an empty one, or the one-byte
    /// shape that predates this contract. See the type's own note on
    /// why absence is not read as a failure.
    static func read(_ data: Data?) -> TunnelResetReply? {
        guard let data, data.count >= 2 else { return nil }
        return TunnelResetReply(rawValue: data[data.startIndex + 1])
    }
}
