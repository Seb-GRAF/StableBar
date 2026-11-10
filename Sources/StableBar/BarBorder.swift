import SwiftUI

/// Observe decoration separately from the bar's width measurement and horizontal planning.
struct BarSurface: ViewModifier {
    let store: BarStore
    let settings: BarSettings
    let kind: ScreenKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let style = store.barStyle(on: kind)
        content
            .clipShape(RoundedRectangle(cornerRadius: max(0, style.cornerRadius ?? 0)))
            .modifier(GlassBackground(fill: style.background ?? settings.background, glass: settings.glass, surface: \.bar,
                                      shape: RoundedRectangle(cornerRadius: max(0, style.cornerRadius ?? 0))))
            .background {
                // A see-through strip shows the popups' surface, which the theme pairs with its text.
                if reduceTransparency {
                    let look = store.configuration!.look(on: kind)
                    Color.clear.modifier(GlassBackground(fill: look.popupDefaults.inheriting(look.defaults).background, glass: settings.glass,
                                                         surface: \.popups, shape: RoundedRectangle(cornerRadius: max(0, style.cornerRadius ?? 0))))
                }
            }
            .overlay { BarBorder(style: style) }
            .animation(reduceMotion ? nil : settings.animation.value, value: style)
    }
}

struct GlassBackground<S: Shape>: ViewModifier {
    let fill: BackgroundFill?
    let glass: GlassSettings
    let surface: KeyPath<GlassSettings, Bool>
    let shape: S
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(macOS 26, *), glass.enabled, glass[keyPath: surface], !reduceTransparency {
            // Keep one view structure while the color comes and goes (hover, open, data states): switching
            // branches rebuilds the content, which dismantles a widget's popup anchor and closes its popup.
            let visible = fill.map { (colorScheme == .dark ? $0.firstColor.dark : $0.firstColor.light) & 0xff > 0 } ?? false
            content.background {
                ZStack {
                    Color.clear.glassEffect(visible ? .clear : .identity, in: shape)
                    shape.fill((fill?.shapeStyle ?? AnyShapeStyle(Color.clear)).opacity(1 - glass.transparency))
                }
            }
        } else {
            let empty = if surface != \GlassSettings.popups {
                AnyShapeStyle(Color.clear)
            } else if reduceTransparency {
                AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
            } else {
                AnyShapeStyle(.regularMaterial)
            }
            // Widgets keep their fill, tints included: they sit on the bar or a popup, which are opaque.
            let fill = reduceTransparency && surface != \GlassSettings.widgets ? self.fill?.opaque : self.fill
            content.background(fill?.shapeStyle ?? empty, in: shape)
        }
    }
}

private extension BackgroundFill {
    var opaque: BackgroundFill {
        switch self {
        case let .color(color): .color(color.opaque)
        case let .gradient(gradient):
            .gradient(BackgroundGradient(colors: gradient.colors.map(\.opaque), angle: gradient.angle, locations: gradient.locations))
        }
    }
}

private extension HexColor {
    /// The color at full opacity. A clear color stays clear: a see-through strip shows the surface `BarSurface` puts under
    /// it, and a popup hides its background while a morph card draws it.
    var opaque: HexColor {
        HexColor(light: light & 0xff == 0 ? light : light | 0xff, dark: dark & 0xff == 0 ? dark : dark | 0xff)
    }
}

extension WidgetAppearance {
    /// Increase Contrast outlines tiles and popups in their text color, which the theme pairs with their background.
    func border(increasedContrast: Bool) -> Color {
        increasedContrast ? foreground : borderColor
    }
}

/// Paint inside the visible strip; neither border choice contributes to layout or hit testing.
/// Shared with Customize so its theme cards show the same outline as the bar.
struct BarBorder: View {
    let style: WidgetStyle

    var body: some View {
        Group {
            if style.borderEdges == .all {
                RoundedRectangle(cornerRadius: max(0, style.cornerRadius ?? 0))
                    .strokeBorder(style.borderColor?.color ?? .clear, lineWidth: max(0, style.borderWidth ?? 0))
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    (style.borderColor?.color ?? .clear).frame(height: max(0, style.borderWidth ?? 0))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
