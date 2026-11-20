import SwiftUI

enum BarExpansion {
    case collapsed, granted, cramped
}

/// Marks the bar's hidden copy that measures widget widths and keeps it still: nothing animates there.
struct MeasuringCopy: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.measuringBarWidths, true)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}

struct BarUnitView: View {
    let unit: BarUnit
    let config: Configuration
    let store: BarStore
    let display: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.measuringBarWidths) private var measuring

    var body: some View {
        if unit.isSpacer {
            Color.clear.frame(minWidth: unit.widgets[0].style.minWidth ?? 0,
                              idealWidth: unit.widgets[0].style.minWidth ?? 0, maxWidth: .infinity, minHeight: 1)
        } else {
            BarUnitSurface(style: unit.style ?? WidgetStyle(), defaults: config.defaults, spacing: config.bar.spacing) {
                ForEach(unit.widgets) { widget in
                    WidgetView(widget: widget, defaults: config.defaults, popupDefaults: config.popupDefaults, store: store,
                               monitor: display, defaultAnimation: config.bar.animation, defaultTransition: config.bar.motion.transition)
                        .environment(\.barUnitID, unit.id)
                        .transition(visibilityTransition(widget.transition ?? config.bar.motion.transition, still: reduceMotion || measuring))
                }
            }
        }
    }
}

/// The same group spacing and surface wrap normal widgets and their edit decorations.
struct BarUnitSurface<Content: View>: View {
    let style: WidgetStyle
    let defaults: WidgetStyle
    let spacing: Double
    @ViewBuilder let content: () -> Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let surface = HStack(spacing: style.spacing ?? spacing, content: content)
            .padding(.leading, style.paddingLeading ?? style.paddingHorizontal ?? 0)
            .padding(.trailing, style.paddingTrailing ?? style.paddingHorizontal ?? 0)
            .padding(.top, style.paddingTop ?? style.paddingVertical ?? 0)
            .padding(.bottom, style.paddingBottom ?? style.paddingVertical ?? 0)
        let fill = style.background?.shapeStyle ?? AnyShapeStyle(Color.clear)
        let shadow = WidgetAppearance(style, defaults: WidgetStyle())
        if let flare = style.flare {
            surface.background { FlaredRectangle(cornerRadius: style.cornerRadius ?? 0, flare: flare).fill(fill).styledShadow(shadow) }
        } else {
            let outlined = contrast == .increased && style.background != nil
            let appearance = WidgetAppearance(WidgetStyle(), defaults: defaults)
            surface
                .background { RoundedRectangle(cornerRadius: style.cornerRadius ?? 0).fill(fill).styledShadow(shadow) }
                .overlay {
                    if outlined {
                        // As in WidgetView, a RoundedRectangle's border would get stray marks at the ends of a pill offscreen.
                        let radius = style.cornerRadius ?? 0
                        UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: radius,
                                               topTrailingRadius: radius)
                            .strokeBorder(appearance.foreground, lineWidth: max(style.borderWidth ?? 1, 1))
                    } else {
                        RoundedRectangle(cornerRadius: style.cornerRadius ?? 0)
                            .strokeBorder(style.borderColor?.color ?? .clear, lineWidth: style.borderWidth ?? 0)
                    }
                }
        }
    }
}

struct FlaredRectangle: Shape {
    let cornerRadius: Double
    let flare: Double

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX - flare, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX + flare, y: rect.minY))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: flare)
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: cornerRadius)
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: cornerRadius)
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX - flare, y: rect.minY), radius: flare)
            path.closeSubpath()
        }
    }
}
