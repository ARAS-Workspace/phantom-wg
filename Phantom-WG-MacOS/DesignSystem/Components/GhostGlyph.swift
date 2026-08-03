import SwiftUI

/// Vector ghost silhouette matching the brand mark — dome top,
/// three-notch skirt, and punched-out eyes (even-odd fill). Drawn as
/// a `Shape` so it scales and tints exactly like an SF Symbol; ghost
/// tunnels show it in place of the shield status icons. Fill with
/// `FillStyle(eoFill: true)` or the eyes stay solid.
struct GhostGlyph: Shape {

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        func at(_ unitX: CGFloat, _ unitY: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + unitX * width, y: rect.minY + unitY * height)
        }

        var path = Path()

        // Body — up the left edge, over the dome, down the right edge.
        path.move(to: at(0.08, 0.96))
        path.addLine(to: at(0.08, 0.46))
        path.addCurve(to: at(0.5, 0.04), control1: at(0.08, 0.20), control2: at(0.26, 0.04))
        path.addCurve(to: at(0.92, 0.46), control1: at(0.74, 0.04), control2: at(0.92, 0.20))
        path.addLine(to: at(0.92, 0.96))

        // Skirt — three upward notches, right to left.
        path.addLine(to: at(0.78, 0.84))
        path.addLine(to: at(0.64, 0.96))
        path.addLine(to: at(0.5, 0.84))
        path.addLine(to: at(0.36, 0.96))
        path.addLine(to: at(0.22, 0.84))
        path.addLine(to: at(0.08, 0.96))
        path.closeSubpath()

        // Eyes — punched out by the even-odd fill.
        path.addEllipse(in: CGRect(
            x: rect.minX + 0.26 * width, y: rect.minY + 0.34 * height,
            width: 0.16 * width, height: 0.16 * height
        ))
        path.addEllipse(in: CGRect(
            x: rect.minX + 0.58 * width, y: rect.minY + 0.34 * height,
            width: 0.16 * width, height: 0.16 * height
        ))

        return path
    }
}

// MARK: - Previews

#Preview {
    HStack(spacing: 24) {
        GhostGlyph()
            .fill(.green, style: FillStyle(eoFill: true))
            .frame(width: 18, height: 18)
        GhostGlyph()
            .fill(.orange, style: FillStyle(eoFill: true))
            .frame(width: 24, height: 24)
        GhostGlyph()
            .fill(.secondary, style: FillStyle(eoFill: true))
            .frame(width: 48, height: 48)
    }
    .padding(40)
}
