import AppKit

@MainActor
final class WorkspaceAppIcons {
    // Fresh NSWorkspace images compare unequal in SwiftUI, even for the same icon.
    // Keep their identity stable while hover and workspace animations redraw the row.
    private struct Key: Hashable {
        let bundleID: String
        let size: NSSize
        let scale: CGFloat
    }
    private var images: [Key: NSImage] = [:]
    private var artworks: [String: NSImage] = [:]
    private let load: (String) -> NSImage?

    init(load: @escaping (String) -> NSImage? = { bundleID in
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }) {
        self.load = load
    }

    func image(for bundleID: String, size: NSSize = NSSize(width: 14, height: 14), scale: CGFloat = 1) -> NSImage? {
        guard size.width > 0, size.height > 0, scale > 0,
              let width = Int(exactly: ceil(size.width * scale)), let height = Int(exactly: ceil(size.height * scale)) else { return nil }
        let key = Key(bundleID: bundleID, size: size, scale: scale)
        if let image = images[key] { return image }
        guard let artwork = artwork(for: bundleID) else { return nil }
        let image: NSImage
        if let pixels = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .high
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
            image = context.makeImage().map { NSImage(cgImage: $0, size: size) } ?? artwork
        } else {
            image = artwork
        }
        images[key] = image
        return image
    }

    private func artwork(for bundleID: String) -> NSImage? {
        if let image = artworks[bundleID] { return image }
        guard let source = load(bundleID) else { return nil }
        // Resolve detailed pixels before the view scales the icon. Keeping the
        // multi-representation image lets AppKit reselect small artwork at draw time.
        let artwork = source.copy() as! NSImage
        artwork.size = NSSize(width: 256, height: 256)
        var rect = NSRect(origin: .zero, size: artwork.size)
        let image = if let pixels = artwork.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            NSImage(cgImage: pixels, size: rect.size)
        } else {
            artwork
        }
        artworks[bundleID] = image
        return image
    }
}
