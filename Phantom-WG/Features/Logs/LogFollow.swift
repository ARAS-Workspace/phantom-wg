import SwiftUI

/// Whether the log screen follows new lines: it does while the reader
/// is at the bottom (or everything fits), and stops once the reader
/// scrolls up. Content growing under a still reader leaves the choice
/// as it was; only a scroll, or content that fits, decides it again.
enum LogFollow {

    static let threshold: CGFloat = 24

    static func isAtBottom(offsetY: CGFloat, visibleHeight: CGFloat, contentHeight: CGFloat) -> Bool {
        contentHeight <= visibleHeight || offsetY + visibleHeight >= contentHeight - threshold
    }

    struct Position: Equatable {
        let offset: CGFloat
        let atBottom: Bool
        let fits: Bool

        init(offset: CGFloat, visibleHeight: CGFloat, contentHeight: CGFloat) {
            self.offset = offset
            self.atBottom = LogFollow.isAtBottom(offsetY: offset, visibleHeight: visibleHeight, contentHeight: contentHeight)
            self.fits = contentHeight <= visibleHeight
        }

        /// On iOS the offset counts the top content inset (the area under
        /// the navigation bar): at the top it reads `-contentInsets.top`,
        /// while `containerSize` is the area between the insets. Adding
        /// the inset back measures the offset from the content's start,
        /// which is what the rule above compares.
        @available(iOS 18.0, *)
        init(_ geometry: ScrollGeometry) {
            self.init(
                offset: geometry.contentOffset.y + geometry.contentInsets.top,
                visibleHeight: geometry.containerSize.height,
                contentHeight: geometry.contentSize.height
            )
        }
    }

    static func follows(after old: Position, _ new: Position, current: Bool) -> Bool {
        new.offset != old.offset || new.fits ? new.atBottom : current
    }
}

extension View {

    /// Keeps `follows` in step with the scroll position on iOS 18 and
    /// later, where SwiftUI reports scroll geometry. Earlier systems
    /// leave it as it is — `true` — so the log screen follows every new
    /// line there.
    @ViewBuilder
    func tracksLogFollow(_ follows: Binding<Bool>) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: LogFollow.Position.self) { geometry in
                LogFollow.Position(geometry)
            } action: { old, new in
                follows.wrappedValue = LogFollow.follows(after: old, new, current: follows.wrappedValue)
            }
        } else {
            self
        }
    }
}
