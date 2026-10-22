import SwiftUI

/// Observe decoration separately from the bar's width measurement and horizontal planning.
struct BarSurface: ViewModifier {
    let store: BarStore
    let settings: BarSettings
    let kind: ScreenKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let style = store.barStyle(on: kind)
        content
            .clipShape(RoundedRectangle(cornerRadius: max(0, style.cornerRadius ?? 0)))
            .modifier(GlassBackground(fill: style.background ?? settings.background, glass: settings.glass, surface: \.bar,
                                      shape: RoundedRectangle(cornerRadius: max(0, style.cornerRadius ?? 0))))
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

    func body(content: Content) -> some View {
        if #available(macOS 26, *), glass.enabled, glass[keyPath: surface] {
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
            let empty = surface == \GlassSettings.popups ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.clear)
            content.background(fill?.shapeStyle ?? empty, in: shape)
        }
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
