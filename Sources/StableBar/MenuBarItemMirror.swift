import AppKit
@preconcurrency import ApplicationServices
import Observation
@preconcurrency import ScreenCaptureKit

/// Copies of menu bar items as macOS draws them, for the items a bar shows live. MenuBarAgent draws the whole
/// menu bar in one window per display from macOS 27 on, also while the menu bar is hidden, so one capture of that
/// window holds every item. Before macOS 27 there is no such window, and live items keep their icons.
@MainActor @Observable
final class MenuBarItemMirror {
    /// The copies, by `MenuBarItem.key`.
    private(set) var images: [String: MenuBarItemImage] = [:]
    @ObservationIgnored var references: [MenuBarItemReference] = [] {
        didSet { if references != oldValue { schedule() } }
    }
    @ObservationIgnored var items: () -> [MenuBarItem] = { [] }
    @ObservationIgnored private let readAttribute: @Sendable (String, AXUIElement) -> CFTypeRef?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var windows: [SCWindow] = []
    /// Listing the windows takes about half a second of the window server's time, so it waits between tries.
    @ObservationIgnored private var nextWindowListing = Date.distantPast

    init(readAttribute: @escaping @Sendable (String, AXUIElement) -> CFTypeRef?) {
        self.readAttribute = readAttribute
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard !references.isEmpty else {
            images = [:]
            return
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    private func refresh() {
        guard !refreshing, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }
        refreshing = true
        Task {
            let images = await copies()
            refreshing = false
            // The items may have stopped being live meanwhile.
            if timer != nil, images != self.images { self.images = images }
        }
    }

    private func copies() async -> [String: MenuBarItemImage] {
        let targets = items().filter { item in references.contains { $0.matches(item) } }.map { Target(key: $0.key, element: $0.entry.element) }
        guard !targets.isEmpty, CGPreflightScreenCaptureAccess(),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: menuBarAgentID).first?.processIdentifier
        else { return [:] }
        let readAttribute = readAttribute
        guard let (frames, folded) = try? await BlockingWork.run({
            var frames: [String: CGRect] = [:]
            for target in targets {
                AXUIElementSetMessagingTimeout(target.element, 0.1)
                let frame = frame(of: target.element, readAttribute)
                if !frame.isEmpty { frames[target.key] = frame }
            }
            return (frames, foldedMenuBarAreas(agent: agent, readAttribute))
        }) else { return [:] }
        // macOS doesn't draw the items it folds behind the overflow button; they keep their icons.
        let collapsed = collapsedMenuBarItems(frames, in: folded)
        let drawn = frames.filter { !collapsed.contains($0.key) }
        guard let frame = drawn.values.first else { return [:] }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        if !windows.contains(where: { $0.frame.contains(point) }) { await listWindows() }
        // A display can have a second menu bar window that holds no items.
        for window in windows where window.frame.contains(point) {
            guard let images = await capture(drawn, in: window) else {
                windows = []
                break
            }
            if !images.isEmpty { return images }
        }
        return [:]
    }

    private func listWindows() async {
        guard Date() >= nextWindowListing else { return }
        nextWindowListing = Date().addingTimeInterval(10)
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        windows = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false))?.windows.filter {
            $0.owningApplication?.bundleIdentifier == menuBarAgentID && $0.windowLayer == level
        } ?? []
    }

    /// The items cut out of one capture of `window`, or nil when it can't be captured, as after MenuBarAgent restarts.
    private func capture(_ frames: [String: CGRect], in window: SCWindow) async -> [String: MenuBarItemImage]? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        configuration.backgroundColor = .clear
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        return frames.compactMapValues { frame in
            let rect = frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
                .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            return image.cropping(to: rect).flatMap { MenuBarItemImage(copying: $0, scale: scale) }
        }
    }
}

/// An item to copy. Accessibility elements can be read from any thread.
private struct Target: @unchecked Sendable {
    let key: String
    let element: AXUIElement
}

/// The part of each menu bar where MenuBarAgent folds the items that don't fit: from the bar's left edge to the
/// right edge of its overflow button, which it puts over them.
func foldedMenuBarAreas(agent: pid_t, _ readAttribute: (String, AXUIElement) -> CFTypeRef?) -> [CGRect] {
    let app = AXUIElementCreateApplication(agent)
    AXUIElementSetMessagingTimeout(app, 0.1)
    return (readAttribute(kAXWindowsAttribute, app) as? [AXUIElement] ?? []).flatMap { window in
        let bar = frame(of: window, readAttribute)
        return (readAttribute(kAXChildrenAttribute, window) as? [AXUIElement] ?? [])
            .filter { readAttribute(kAXIdentifierAttribute, $0) as? String == "menu-bar-overflow-indicator" }
            .map { frame(of: $0, readAttribute) }
            .filter { !$0.isEmpty }
            .map { CGRect(x: bar.minX, y: $0.minY, width: $0.maxX - bar.minX, height: $0.height) }
    }
}

/// The items macOS folds behind an overflow button: those whose middle is in a folded area.
func collapsedMenuBarItems(_ frames: [String: CGRect], in folded: [CGRect]) -> Set<String> {
    Set(frames.filter { _, frame in folded.contains { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) } }.keys)
}

/// A menu bar item's pixels, without the empty columns at its sides.
struct MenuBarItemImage: Equatable {
    let image: NSImage
    private let pixels: Data

    /// Whether the item is drawn in one color, as most are: the bar then draws it in its own color.
    var isTemplate: Bool { image.isTemplate }

    static func == (first: MenuBarItemImage, second: MenuBarItemImage) -> Bool {
        first.pixels == second.pixels && first.image.size == second.image.size && first.isTemplate == second.isTemplate
    }

    /// Nil when `source` holds nothing, as for an item macOS isn't drawing.
    init?(copying source: CGImage, scale: CGFloat) {
        let width = source.width, height = source.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let format = CGImageAlphaInfo.premultipliedLast.rawValue
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: format),
              let data = context.data else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        func brightness(_ pixel: Int) -> Double {
            0.299 * Double(bytes[pixel]) + 0.587 * Double(bytes[pixel + 1]) + 0.114 * Double(bytes[pixel + 2])
        }
        var left = width, right = -1, solid = 0, colored = 0, light = 0.0, opacity = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let pixel = (y * width + x) * 4
                let alpha = Int(bytes[pixel + 3])
                guard alpha > 12 else { continue }
                left = min(left, x)
                right = max(right, x)
                light += brightness(pixel)
                opacity += Double(alpha)
                guard alpha > 64 else { continue }
                let channels = [Int(bytes[pixel]), Int(bytes[pixel + 1]), Int(bytes[pixel + 2])]
                solid += 1
                if channels.max()! - channels.min()! > alpha / 5 { colored += 1 }
            }
        }
        guard right >= left else { return nil }
        let isTemplate = colored * 50 <= solid
        if isTemplate {
            // Dimmer parts of a white item are gray rather than transparent, so brightness becomes opacity; a black item's, the reverse.
            let isLight = light > opacity / 2
            for pixel in stride(from: 0, to: width * height * 4, by: 4) {
                let brightness = brightness(pixel)
                let alpha = isLight ? brightness : Double(bytes[pixel + 3]) - brightness
                (bytes[pixel], bytes[pixel + 1], bytes[pixel + 2]) = (0, 0, 0)
                bytes[pixel + 3] = UInt8(max(0, min(255, alpha.rounded())))
            }
        }
        let trimmedWidth = right - left + 1
        var pixels = Data(capacity: trimmedWidth * height * 4)
        for y in 0..<height {
            pixels.append(bytes + (y * width + left) * 4, count: trimmedWidth * 4)
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let trimmed = CGImage(width: trimmedWidth, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: trimmedWidth * 4,
                                    space: space, bitmapInfo: CGBitmapInfo(rawValue: format), provider: provider, decode: nil,
                                    shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        image = NSImage(cgImage: trimmed, size: NSSize(width: CGFloat(trimmedWidth) / scale, height: CGFloat(height) / scale))
        image.isTemplate = isTemplate
        self.pixels = pixels
    }
}
