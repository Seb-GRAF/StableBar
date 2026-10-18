import SwiftUI
import XCTest
@testable import StableBar

final class ThemeCardTests: XCTestCase {
    @MainActor func testCardImmediatelyDrawsSampleContentWithinItsProposedWidth() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let choice = try fixture.theme(##"{"defaults":{"foreground":"#ff00ff","accent":"#ff00ff"}}"##, install: false)
        let look = try ThemePreview(choice: choice, themesDirectory: fixture.themes).light
        for isStore in [false, true] {
            for width: CGFloat in [280, 580] {
                let card = ThemeCard(title: "Sample theme", look: look, isSelected: !isStore, isStore: isStore, select: {})
                let host = NSHostingView(rootView: card.frame(width: width))
                host.frame = CGRect(x: 0, y: 0, width: width, height: 110)
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 0.5)
                XCTAssertGreaterThan(host.fittingSize.height, 76)
                XCTAssertLessThan(host.fittingSize.height, 130)
                // Draw offscreen on the first pass, without a window, screen or measurement update.
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: 110,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                var samplePixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        if let color = bitmap.colorAt(x: x, y: y),
                           color.alphaComponent > 0.8 && color.redComponent > 0.8 && color.blueComponent > 0.8 && color.greenComponent < 0.2 {
                            samplePixels += 1
                        }
                    }
                }
                XCTAssertGreaterThan(samplePixels, 50, "The first draw must show the sample, not just the card background")
            }
        }
    }

    @MainActor func testCardUsesTheBarAppearanceForItsStrip() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let choice = try fixture.theme(##"{"bar":{"style":{"background":{"light":"#ff0000","dark":"#0000ff"}}}}"##, install: false)
        let preview = try ThemePreview(choice: choice, themesDirectory: fixture.themes)
        for appearance in [BarAppearance.light, .dark] {
            let card = ThemeCard(title: "Sample", look: preview.configuration(for: appearance), appearance: appearance, select: {})
            let renderer = ImageRenderer(content: card.frame(width: 580)
                .environment(\.colorScheme, appearance == .dark ? .light : .dark))
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let color = try XCTUnwrap(bitmap.colorAt(x: 290, y: 38))
            XCTAssertEqual(color.redComponent, appearance == .light ? 1 : 0, accuracy: 0.01)
            XCTAssertEqual(color.blueComponent, appearance == .dark ? 1 : 0, accuracy: 0.01)
        }
    }

    @MainActor func testEveryBundledThemeCardFitsTheProposedWidth() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        for choice in ThemeCatalog(packages: fixture.packages.directory, themesDirectory: fixture.themes).choices {
            let preview = try ThemePreview(choice: choice, themesDirectory: fixture.themes)
            for appearance in [BarAppearance.light, .dark] {
                let card = ThemeCard(title: choice.title, look: preview.configuration(for: appearance), appearance: appearance, select: {})
                let renderer = ImageRenderer(content: card)
                renderer.proposedSize = ProposedViewSize(width: 280, height: nil)
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertLessThanOrEqual(image.width, 280, choice.title)
                XCTAssertGreaterThan(image.height, 76)
                XCTAssertLessThan(image.height, 130)
            }
        }
    }
}
