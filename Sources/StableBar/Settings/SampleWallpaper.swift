import AppKit
import SwiftUI

/// What previews of the bar show behind it: the Mac's wallpaper when it's one of Apple's, otherwise a drawn backdrop in
/// the preview's appearance. Offscreen, it shows the scene's wallpaper or the backdrop, never the Mac's wallpaper.
struct SampleWallpaper: View {
    /// The main screen's wallpaper, read once at a size that many previews draw quickly. Only Apple's wallpapers, in
    /// /System or /Library, are read: a picture in the home folder, iCloud or another app's data can show a privacy prompt.
    static let desktop: NSImage? = {
        guard let screen = NSScreen.screens.first, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              url.path.hasPrefix("/System/") || url.path.hasPrefix("/Library/"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                           kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }()
    @Environment(\.offscreenSnapshot) private var offscreen
    @Environment(\.sceneWallpaper) private var sceneWallpaper
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = offscreen ? sceneWallpaper : Self.desktop {
                Color.clear.overlay(alignment: .top) { Image(nsImage: image).resizable().scaledToFill() }.clipped()
            } else {
                backdrop
            }
        }
        // Clipping the scaled image only limits its drawing, not its hit area.
        .allowsHitTesting(false)
    }

    /// Soft glows over a calm gradient, in the spirit of macOS's abstract wallpapers: pastel in light, deep in dark.
    private var backdrop: some View {
        let dark = colorScheme == .dark
        let base: [UInt32] = dark ? [0x141a33ff, 0x231a3dff] : [0xd9e6f7ff, 0xe9def3ff]
        let glows: [UInt32] = dark ? [0x7a3f6ed9, 0x2a5d8fcc, 0x4b3a8cb3] : [0xffc9a8ff, 0xa9d4f5ff, 0xd7c4f2ff]
        return ZStack {
            LinearGradient(colors: base.map { HexColor($0).color }, startPoint: .topLeading, endPoint: .bottomTrailing)
            glow(glows[0], at: UnitPoint(x: 0.15, y: 0.95), size: 0.75)
            glow(glows[1], at: UnitPoint(x: 0.85, y: 0.1), size: 0.7)
            glow(glows[2], at: UnitPoint(x: 0.55, y: 0.6), size: 0.5)
        }
    }

    private func glow(_ color: UInt32, at center: UnitPoint, size: CGFloat) -> some View {
        EllipticalGradient(colors: [HexColor(color).color, .clear], center: center, endRadiusFraction: size)
    }
}

extension EnvironmentValues {
    /// The wallpaper a scene gives the previews of the bar it draws.
    @Entry var sceneWallpaper: NSImage?
}
