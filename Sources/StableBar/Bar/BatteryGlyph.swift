import SwiftUI

/// A battery like the one in the macOS menu bar: its fill shows the charge, a bolt shows it
/// charging and a plug shows the Mac on its adapter without charging. A badge marks a battery macOS
/// recommends servicing. It is sized from the icon size and drawn in the text color, with a red
/// fill when it runs low on battery power.
struct BatteryGlyph: View {
    enum Power: Equatable {
        case battery, charging, plugged
    }

    let level: Double
    let power: Power
    let needsService: Bool
    let iconSize: Double

    /// At or below this charge, on battery power, the fill turns red.
    static let low = 0.1

    /// A battery block's glyph from its fields: `state` is a battery provider's (`charging`, or
    /// `charged` on the adapter), and a `health` of `service` adds the badge.
    init(level: Double, fields: [String: String], iconSize: Double) {
        let power: Power = switch fields["state"] {
        case "charging": .charging
        case "charged", "ac": .plugged
        default: .battery
        }
        self.init(level: level, power: power, needsService: fields["health"] == "service", iconSize: iconSize)
    }

    init(level: Double, power: Power, needsService: Bool, iconSize: Double) {
        self.level = level.isFinite ? min(max(level, 0), 1) : 0
        self.power = power
        self.needsService = needsService
        self.iconSize = iconSize
    }

    /// The body's height; the rest of the glyph follows from it.
    private var height: Double { (iconSize * 0.8).rounded() }
    private var bodyWidth: Double { (height * 2.1).rounded() }
    private var nubWidth: Double { max(1.5, height * 0.15) }
    var size: CGSize { CGSize(width: bodyWidth + 0.5 + nubWidth, height: height) }

    var body: some View {
        Canvas { context, _ in draw(in: &context) }
            .frame(width: size.width, height: size.height)
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
    }

    var accessibilityLabel: String {
        var label = "Battery \(Int((level * 100).rounded())) percent"
        switch power {
        case .battery: break
        case .charging: label += ", charging"
        case .plugged: label += ", plugged in"
        }
        if needsService { label += ", service recommended" }
        return label
    }

    private func draw(in context: inout GraphicsContext) {
        let line = max(1, height / 10)
        let outer = CGRect(x: 0, y: 0, width: bodyWidth, height: height)
        let radius = height * 0.3
        // The outline and nub are dimmed, as in the menu bar, so the fill reads as the charge.
        var frame = context
        frame.opacity = 0.45
        frame.stroke(Path(roundedRect: outer.insetBy(dx: line / 2, dy: line / 2), cornerRadius: radius - line / 2),
                     with: .foreground, style: StrokeStyle(lineWidth: line))
        let nub = CGRect(x: bodyWidth + 0.5, y: height * 0.32, width: nubWidth, height: height * 0.36)
        frame.fill(UnevenRoundedRectangle(bottomTrailingRadius: nubWidth * 0.7, topTrailingRadius: nubWidth * 0.7).path(in: nub),
                   with: .foreground)

        let inset = line + max(1, height / 10)
        let inner = outer.insetBy(dx: inset, dy: inset)
        if level > 0 {
            let fill = CGRect(x: inner.minX, y: inner.minY, width: max(inner.height * 0.3, inner.width * level), height: inner.height)
            let shading: GraphicsContext.Shading = power == .battery && level <= Self.low ? .color(.red) : .foreground
            context.fill(Path(roundedRect: fill, cornerRadius: max(0, radius - inset)), with: shading)
        }

        let symbol: (name: String, height: Double)? = switch power {
        case .battery: nil
        case .charging: ("bolt.fill", height * 1.05)
        case .plugged: ("powerplug.fill", inner.height * 1.05)
        }
        if let symbol {
            var image = context.resolve(Image(systemName: symbol.name))
            let width = image.size.width / max(image.size.height, 1) * symbol.height
            let rect = CGRect(x: outer.midX - width / 2, y: outer.midY - symbol.height / 2, width: width, height: symbol.height)
            knockOut(image, in: rect, gap: line * 1.1, from: &context)
            image.shading = .foreground
            context.draw(image, in: rect)
        }

        if needsService {
            let diameter = (height * 0.66).rounded()
            let badge = CGRect(x: size.width - diameter, y: 0, width: diameter, height: diameter)
            var cut = context
            cut.blendMode = .destinationOut
            cut.fill(Path(ellipseIn: badge.insetBy(dx: -line, dy: -line)), with: .color(.black))
            context.fill(Path(ellipseIn: badge), with: .color(.orange))
        }
    }

    /// Clears `image` and a `gap` around it, so the symbol drawn there stands apart from the fill
    /// and the outline.
    private func knockOut(_ image: GraphicsContext.ResolvedImage, in rect: CGRect, gap: Double, from context: inout GraphicsContext) {
        var cut = context
        cut.blendMode = .destinationOut
        var mask = image
        mask.shading = .color(.black)
        for step in 0..<12 {
            let angle = Double(step) / 12 * 2 * .pi
            cut.draw(mask, in: rect.offsetBy(dx: cos(angle) * gap, dy: sin(angle) * gap))
        }
        cut.draw(mask, in: rect)
    }
}
