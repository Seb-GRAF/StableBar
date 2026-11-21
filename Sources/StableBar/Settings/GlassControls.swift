import SwiftUI

/// The controls Share My Bar and setup draw over an image or a wallpaper.
extension View {
    /// A translucent fill and edge. Their capsules are circular: a continuous capsule's edge gets a stray straight line
    /// beside it in offscreen drawings.
    func glass(_ shape: some InsettableShape) -> some View {
        background(.white.opacity(0.15), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.24), lineWidth: 0.5))
    }
}

/// A capsule button on glass: a segment, a tool, or the primary action, which is `selected` like the chosen segment.
struct GlassButtonStyle: ButtonStyle {
    enum Size { case compact, regular, large }

    var selected: Bool
    var highlighted = false
    var round = false
    var size = Size.regular
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let (font, padding, height): (Double, Double, Double) = switch size {
        case .compact: (11.5, 10, 26)
        case .regular: (12, 12, 36)
        case .large: (15, 22, 48)
        }
        return configuration.label
            .font(.system(size: font, weight: .semibold))
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.horizontal, round ? 0 : padding)
            .frame(minWidth: size == .compact ? 0 : height, minHeight: height)
            .background(fill(pressed: configuration.isPressed), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }

    private func fill(pressed: Bool) -> Color {
        if selected { return .white.opacity(pressed ? 0.75 : 0.92) }
        return .white.opacity(pressed ? 0.28 : highlighted ? 0.22 : 0)
    }
}

/// The round × in a corner, which Esc presses too.
struct GlassCloseButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .glass(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A pill that opens a menu: its title and a chevron.
struct GlassPill<Title: View>: View {
    @ViewBuilder let title: Title

    var body: some View {
        HStack(spacing: 6) {
            title
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.8)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .glass(Capsule(style: .circular))
        .contentShape(Capsule())
    }
}
