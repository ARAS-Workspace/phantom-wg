import SwiftUI

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

        init(_ geometry: ScrollGeometry) {
            self.init(
                offset: geometry.contentOffset.y,
                visibleHeight: geometry.containerSize.height,
                contentHeight: geometry.contentSize.height
            )
        }
    }

    static func follows(after old: Position, _ new: Position, current: Bool) -> Bool {
        new.offset != old.offset || new.fits ? new.atBottom : current
    }
}
