import AppKit
import SwiftUI

/// Draws views to PNG files in offscreen windows, for the docs images and scene files. Nothing appears
/// on screen, and every clock in the drawing shows `DocsImages.date`.
@MainActor
enum OffscreenSnapshot {
    private static let darkBackdrop = Bundle.main.url(forResource: "SetupAmberDark", withExtension: "heic").flatMap(NSImage.init(contentsOf:))

    /// The setup tour's amber wallpaper, or a flat color where the app's resources aren't bundled, as in tests.
    @ViewBuilder static func backdrop(dark: Bool) -> some View {
        if let image = dark ? darkBackdrop : Wallpaper.image {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Color(white: dark ? 0.16 : 0.9)
        }
    }

    /// Draws `content` at twice `size` in an offscreen window below the desktop icons and writes it to
    /// `url` as PNG. It waits for `ready`, at most a minute, then runs `prepare` and lets the views
    /// settle for `settle` before drawing.
    static func write(_ content: some View, size: NSSize, dark: Bool, settle: Duration, ready: () -> Bool = { true },
                      prepare: () -> Void = {}, to url: URL) async throws {
        let view = NSHostingView(rootView: content
            .environment(\.fixedDate, DocsImages.date)
            .environment(\.offline, true)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.14))))
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
        let deadline = ContinuousClock.now + .seconds(60)
        while !ready() {
            guard ContinuousClock.now < deadline else {
                throw CommandFailure(message: "\(url.deletingPathExtension().lastPathComponent): the views weren't ready after a minute.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        prepare()
        try await Task.sleep(for: settle)
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        image.size = size
        view.cacheDisplay(in: view.bounds, to: image)
        try image.representation(using: .png, properties: [:])!.write(to: url)
    }
}
