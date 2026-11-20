import SwiftUI

extension View {
    /// Draws this app icon in its own colors, or tinted in `color`: its light parts strongest when the color reads light
    /// and its dark parts when it reads dark, over a faint silhouette, so light and dark icons both stay visible.
    func styledAppIcon(_ appIcons: AppIcons, color: Color) -> some View {
        modifier(AppIconTint(appIcons: appIcons, color: color))
    }
}

/// Whether text in `color` reads light, on a darker surface. Text sits on the surface of its appearance unless it's too
/// close to it to read there, under about 2:1 contrast with white or black, as text on an accent's fill is: so a muted
/// gray reads dark in light mode and light in dark mode.
func readsLight(_ color: Color.Resolved, in colorScheme: ColorScheme) -> Bool {
    let luminance = 0.2126 * color.linearRed + 0.7152 * color.linearGreen + 0.0722 * color.linearBlue
    return luminance > (colorScheme == .dark ? 0.05 : 0.5)
}

private struct AppIconTint: ViewModifier {
    let appIcons: AppIcons
    let color: Color
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        switch appIcons {
        case .color:
            content
        case .tinted:
            let light = readsLight(color.resolve(in: environment), in: environment.colorScheme)
            content.hidden()
                .overlay {
                    ZStack {
                        Rectangle().fill(color.opacity(0.3))
                        Rectangle().fill(color).mask {
                            if light { content.luminanceToAlpha() } else { content.colorInvert().luminanceToAlpha() }
                        }
                    }
                    .mask { content }
                }
                // Offscreen snapshots, such as scenes and Share My Bar, leave these effects out unless they're drawn as one image.
                .drawingGroup()
        }
    }
}
