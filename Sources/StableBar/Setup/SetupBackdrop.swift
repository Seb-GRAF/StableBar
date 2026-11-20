import AppKit
import CoreImage

/// Setup's full-screen backdrop: the wallpaper at the screen's size, or a drawn one where StableBar can't read it, and a
/// blurred copy the tour crossfades to. Both are made once, off the main thread: Core Animation draws a live blur of a
/// layer this large from a small copy of it, in coarse blocks of flat color.
@MainActor @Observable final class SetupBackdrop {
    struct Images: Sendable {
        let sharp: CGImage
        let soft: CGImage
    }

    enum Wallpaper: Sendable {
        case file(URL)
        case image(CGImage)
    }

    private(set) var images: Images?

    /// Makes the images for a screen `pixels` large, with the drawn backdrop in dark or light when `wallpaper` is nil or
    /// can't be read.
    func load(_ wallpaper: Wallpaper?, pixels: CGSize, dark: Bool) async {
        let images = await Task.detached(priority: .userInitiated) {
            let sharp = wallpaper.flatMap { Self.filling(pixels, with: $0) } ?? Self.drawn(CGSize(width: pixels.width / 2, height: pixels.height / 2), dark: dark)
            return Images(sharp: sharp, soft: Self.blurred(sharp) ?? sharp)
        }.value
        // A load for the Mac's earlier appearance, cancelled by a newer one, leaves the newer one's images.
        guard !Task.isCancelled else { return }
        self.images = images
    }

    /// The middle of `wallpaper`, cut to the screen's shape and read no larger than it fills the screen, as macOS's Fill
    /// Screen shows it.
    nonisolated private static func filling(_ pixels: CGSize, with wallpaper: Wallpaper) -> CGImage? {
        let image: CGImage
        switch wallpaper {
        case .image(let scene):
            image = scene
        case .file(let url):
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Double, let height = properties[kCGImagePropertyPixelHeight] as? Double,
                  let read = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: (max(width, height) * min(1, max(pixels.width / width, pixels.height / height))).rounded(.up)
                  ] as CFDictionary)
            else { return nil }
            image = read
        }
        let size = CGSize(width: image.width, height: image.height)
        let fill = max(pixels.width / size.width, pixels.height / size.height)
        let cut = CGSize(width: pixels.width / fill, height: pixels.height / fill)
        return image.cropping(to: CGRect(x: ((size.width - cut.width) / 2).rounded(), y: ((size.height - cut.height) / 2).rounded(),
                                         width: cut.width.rounded(), height: cut.height.rounded()))
    }

    /// Soft light over a calm gradient, in the spirit of macOS's abstract wallpapers: bright in light, deep in dark, and
    /// rich enough in both to stay colorful once the tour dims it. Drawn with 16-bit color, so its wide gradients don't
    /// band.
    nonisolated private static func drawn(_ pixels: CGSize, dark: Bool) -> CGImage {
        let width = Int(pixels.width), height = Int(pixels.height)
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder16Little.rawValue)!
        func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
            CGColor(colorSpace: space, components: [Double(hex >> 16 & 0xff) / 255, Double(hex >> 8 & 0xff) / 255, Double(hex & 0xff) / 255, alpha])!
        }
        let base: [UInt32] = dark ? [0x0b0d1f, 0x1c1233] : [0x9fc8f7, 0xd6c6f6]
        context.drawLinearGradient(CGGradient(colorsSpace: space, colors: base.map { color($0) } as CFArray, locations: [0, 1])!,
                                   start: CGPoint(x: 0, y: pixels.height), end: .zero, options: [])
        // Each light: its color, its center from the top left and its reach, as fractions of the screen, and its strength.
        let lights: [(UInt32, CGPoint, CGSize, Double)] = dark
            ? [(0x5a3fd6, CGPoint(x: 0.16, y: 0.92), CGSize(width: 0.78, height: 0.8), 0.8),
               (0x2763c4, CGPoint(x: 0.9, y: 0.06), CGSize(width: 0.62, height: 0.7), 0.7),
               (0xd2477e, CGPoint(x: 0.66, y: 1.02), CGSize(width: 0.5, height: 0.45), 0.55),
               (0xff9f4a, CGPoint(x: 0.42, y: 0.62), CGSize(width: 0.32, height: 0.26), 0.16)]
            : [(0xff9a78, CGPoint(x: 0.12, y: 0.94), CGSize(width: 0.72, height: 0.8), 0.85),
               (0x4f93f2, CGPoint(x: 0.9, y: 0.05), CGSize(width: 0.66, height: 0.74), 0.75),
               (0x9b7ef0, CGPoint(x: 0.62, y: 0.64), CGSize(width: 0.46, height: 0.46), 0.65),
               (0xffd27a, CGPoint(x: 0.34, y: 0.32), CGSize(width: 0.36, height: 0.32), 0.5)]
        for (hex, center, reach, strength) in lights {
            let gradient = CGGradient(colorsSpace: space, colors: [color(hex, strength), color(hex, strength * 0.45), color(hex, 0)] as CFArray,
                                      locations: [0, 0.45, 1])!
            context.saveGState()
            context.translateBy(x: center.x * pixels.width, y: (1 - center.y) * pixels.height)
            context.scaleBy(x: reach.width * pixels.width, y: reach.height * pixels.height)
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            context.restoreGState()
        }
        return context.makeImage()!
    }

    /// Blurred and a little richer at an eighth of the size, which the tour scales back up: a blur this wide hides the
    /// difference.
    nonisolated private static func blurred(_ image: CGImage) -> CGImage? {
        let small = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 0.125, y: 0.125))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 12)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.2])
            .cropped(to: small.extent)
        return CIContext().createCGImage(blurred, from: small.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
    }
}
