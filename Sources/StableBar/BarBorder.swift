import SwiftUI

/// Observe decoration separately from the bar's width measurement and horizontal planning.
struct BarSurface: ViewModifier {
    let store: BarStore
    let settings: BarSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let style = store.barStyle
        content
            .clipShape(RoundedRectangle(cornerRadius: max(0, style.cornerRadius ?? 0)))
            .modifier(GlassBackground(color: style.background ?? settings.background, glass: settings.glass, surface: \.bar,
                                      shape: RoundedRectangle(cornerRadius: max(0, style.cornerRadius ?? 0))))
            .overlay { BarBorder(style: style) }
            .animation(reduceMotion ? nil : .easeOut(duration: settings.animationDuration), value: style)
    }
}

struct GlassBackground<S: Shape>: ViewModifier {
    let color: HexColor?
    let glass: GlassSettings
    let surface: KeyPath<GlassSettings, Bool>
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(macOS 26, *), glass.enabled, glass[keyPath: surface], let color,
           (colorScheme == .dark ? color.dark : color.light) & 0xff > 0 {
            content.background {
                ZStack {
                    Color.clear.glassEffect(.clear, in: shape)
                    shape.fill(color.color.opacity(1 - glass.transparency))
                }
            }
        } else {
            content.background(color?.color ?? .clear, in: shape)
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
