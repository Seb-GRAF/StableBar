import AppKit
import SwiftUI

/// What previews of the bar show behind it: the Mac's wallpaper when StableBar can read it without a privacy prompt,
/// otherwise a drawn backdrop in the preview's appearance. Offscreen, it shows the scene's wallpaper or the backdrop,
/// never the Mac's wallpaper.
struct SampleWallpaper: View {
    @Environment(\.offscreenSnapshot) private var offscreen
    @Environment(\.sceneWallpaper) private var sceneWallpaper
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = offscreen ? sceneWallpaper : DesktopWallpaper.shared.image {
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

/// The main screen's wallpaper, read once, off the main thread, at a size that many previews draw quickly.
@MainActor @Observable private final class DesktopWallpaper {
    static let shared = DesktopWallpaper()
    private(set) var image: NSImage?

    private init() {
        guard let screen = NSScreen.screens.first, let url = NSWorkspace.shared.readableDesktopImageURL(for: screen) else { return }
        Task {
            let thumbnail = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary)
            }.value
            image = thumbnail.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}

extension NSWorkspace {
    /// `screen`'s wallpaper, when StableBar can read it without a privacy prompt.
    func readableDesktopImageURL(for screen: NSScreen) -> URL? {
        desktopImageURL(for: screen).flatMap { wallpaperReadsWithoutPrompt($0, home: FileManager.default.homeDirectoryForCurrentUser) ? $0 : nil }
    }
}

/// Whether macOS lets StableBar read the picture at `url` without asking: Apple's wallpapers in /System or /Library, or
/// one in ~/Pictures outside a Photos library. Desktop, Documents, Downloads, iCloud Drive, other apps' data and other
/// volumes can show a privacy prompt. /System/Volumes/Data holds the home folder too.
func wallpaperReadsWithoutPrompt(_ url: URL, home: URL) -> Bool {
    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
    let pictures = home.appending(path: "Pictures").resolvingSymlinksInPath().standardizedFileURL.path + "/"
    guard (path.hasPrefix("/System/") && !path.hasPrefix("/System/Volumes/Data/")) || path.hasPrefix("/Library/") || path.hasPrefix(pictures)
    else { return false }
    return !path.split(separator: "/").contains { $0.hasSuffix(".photoslibrary") }
}

extension EnvironmentValues {
    /// The wallpaper a scene gives the previews of the bar it draws.
    @Entry var sceneWallpaper: NSImage?
}
