import CoreGraphics

enum WindowSizing {

    static let ideal = CGSize(width: 640, height: 720)
    static let minimum = CGSize(width: 520, height: 480)
    static let widthShare: CGFloat = 0.9
    static let heightShare: CGFloat = 0.75

    static func defaultSize(visible: CGSize) -> CGSize {
        CGSize(
            width: max(minimum.width, min(ideal.width, (visible.width * widthShare).rounded(.down))),
            height: max(minimum.height, min(ideal.height, (visible.height * heightShare).rounded(.down)))
        )
    }

    static func defaultFrame(in visible: CGRect) -> CGRect {
        let size = defaultSize(visible: visible.size)
        return CGRect(
            x: (visible.midX - size.width / 2).rounded(.down),
            y: (visible.midY - size.height / 2).rounded(.down),
            width: size.width,
            height: size.height
        )
    }
}
