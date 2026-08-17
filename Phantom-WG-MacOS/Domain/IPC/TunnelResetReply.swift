import Foundation

/// Opcode `3`'s reply, on the wire.
///
/// The app↔extension provider-message channel is a byte protocol: the
/// first byte of the request is the opcode. What comes BACK differs by
/// opcode and always has — 0 answers a uapi dump, 1 a JSON log blob,
/// and only 2 echoes its own opcode and says nothing else. Opcode 3
/// answered like 2, and that is the shape this type extends; nothing
/// here licenses prefixing an opcode onto 0's or 1's payload, which
/// their readers consume whole. Opcode 3 asks the
/// extension to rebuild its tunnel layer in place, and its four exits
/// — nothing to rebuild, wstunnel refused to come back, the adapter
/// refused to come back, and a clean rebuild — all left the same
/// single byte behind. So a caller could not tell a layer that came
/// back from one that stayed down, and nothing in the app ever tried:
/// the reply was discarded at the only site that read it.
///
/// The reply now carries a SECOND byte, and this type is what both
/// sides speak. The extension writes it on the real path, and the
/// preview provider and the DEBUG fake write it standing in for the
/// extension; the app is the only READER.
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
/// for. So absence is `Reading.absent` rather than a case of this
/// enum — there are four cases and every one of them is a thing the
/// extension SAID — and the app treats an absent byte as it treated
/// any reply before the byte existed. This matters for a window
/// narrower than it looks: app and extension ship together, but the
/// extension the system is running is the one approved before the
/// update, so the pair is mismatched for exactly as long as it takes
/// the new extension to be activated.
///
/// AND AN UNRECOGNISED BYTE IS NOT ABSENCE. `read(_:)` first returned
/// `nil` for both, which extended the argument above to a case it
/// does not cover: a byte this app has no case for is not silence,
/// it is a NEWER extension naming an ending added after this app
/// shipped. Reading it as success claims a rebuilt layer nobody
/// reported. It reaches the user as its own sentence instead —
/// deliberately not as a failure either, because the ending it names
/// may well be a benign one; what is said is that the answer could
/// not be read, which is the only thing that was observed.
///
/// Nothing logs the older-extension window. `resetConnection(of:)`
/// returns silently on `.absent`, and the sentences that name an
/// absent byte live in the suite, against a fake that can produce
/// one. A field reader looking for a mismatched pair has the suite's
/// account and this note, not a live line — said here rather than
/// promised.
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

    /// What a reply's bytes amount to. THREE answers, because the
    /// wire really does carry three different situations and the
    /// first version of this method collapsed two of them into `nil`.
    enum Reading: Sendable, Equatable {
        /// No outcome byte at all: a missing reply, an empty one, or
        /// the one-byte shape that predates this contract.
        case absent
        /// A byte this app has a case for.
        case outcome(TunnelResetReply)
        /// A byte that is present and is NOT one of ours — a build
        /// newer than this app, reporting an ending added after it.
        case unrecognised(UInt8)
    }

    /// Reads the outcome byte, keeping "said nothing" apart from
    /// "said something I cannot read". See the type's own note on why
    /// those two must not share an answer.
    static func read(_ data: Data?) -> Reading {
        guard let data, data.count >= 2 else { return .absent }
        let raw = data[data.startIndex + 1]
        guard let reply = TunnelResetReply(rawValue: raw) else { return .unrecognised(raw) }
        return .outcome(reply)
    }
}
