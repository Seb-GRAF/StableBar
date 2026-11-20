import AppKit
import SwiftUI

/// Draws views to PNG images in offscreen windows, for the docs images, scene files and Share My Bar. Nothing
/// appears on screen.
@MainActor
enum OffscreenSnapshot {
    private static let darkBackdrop = Bundle.main.url(forResource: "SetupDusk", withExtension: "heic").flatMap(NSImage.init(contentsOf:))

    /// The setup tour's wallpaper, or a flat color where the app's resources aren't bundled, as in tests.
    @ViewBuilder static func backdrop(dark: Bool) -> some View {
        if let image = dark ? darkBackdrop : Wallpaper.image {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Color(white: dark ? 0.16 : 0.9)
        }
    }

    /// Draws `content` at twice `size`, with every clock showing `DocsImages.date` and the version row showing
    /// `AppVersion.sample`, and writes it to `url` as PNG.
    static func write(_ content: some View, size: NSSize, dark: Bool, settle: Duration, ready: () -> Bool = { true },
                      prepare: () -> Void = {}, to url: URL) async throws {
        let framed = content
            .environment(\.fixedDate, DocsImages.date)
            .environment(\.fixedVersion, AppVersion.sample)
            .environment(\.offline, true)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.14)))
        try await png(framed, size: size, pixels: NSSize(width: size.width * 2, height: size.height * 2), dark: dark, settle: settle,
                      ready: ready, prepare: prepare, name: url.deletingPathExtension().lastPathComponent).write(to: url)
    }

    /// Draws `content`, laid out `size` points large, to a PNG image `pixels` large in an offscreen window below the
    /// desktop icons. It checks `ready` every tenth of a second, at most 600 times, then runs `prepare` and lets the
    /// views settle for `settle` before drawing. Errors start with `name`.
    static func png(_ content: some View, size: NSSize, pixels: NSSize, dark: Bool, settle: Duration, ready: () -> Bool = { true },
                    prepare: () -> Void = {}, name: String) async throws -> Data {
        let view = NSHostingView(rootView: content.environment(\.offscreenSnapshot, true))
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -9000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Counted, not timed: the views get ready on the main actor, so whatever else holds it delays them as much.
        var checks = 0
        while !ready() {
            guard checks < 600 else {
                throw CommandFailure(message: "\(name): the views weren't ready after a minute.")
            }
            checks += 1
            try await Task.sleep(for: .milliseconds(100))
        }
        prepare()
        try await Task.sleep(for: settle)
        guard let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CommandFailure(message: "\(name): no image of \(Int(size.width)) × \(Int(size.height)) points.")
        }
        image.size = size
        view.cacheDisplay(in: view.bounds, to: image)
        guard let png = image.representation(using: .png, properties: [:]) else {
            throw CommandFailure(message: "\(name): the image couldn't be encoded as PNG.")
        }
        return png
    }
}
