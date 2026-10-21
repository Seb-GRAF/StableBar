import AppKit
import ApplicationServices
import SwiftUI
import Testing
@testable import StableBar

private final class MenuApplication: NSRunningApplication, @unchecked Sendable {
    let pid: pid_t
    override var processIdentifier: pid_t { pid }
    override var bundleIdentifier: String? { "test.menu.\(pid)" }

    init(pid: pid_t) {
        self.pid = pid
        super.init()
    }
}

@MainActor private final class MenuReadFixture {
    var trusted = true
    var failedAttribute: String?
    var empty = false
    var title = "First"
    var reads: [pid_t] = []
    let menuBar = AXUIElementCreateApplication(10)
    let apple = AXUIElementCreateApplication(11)
    let app = AXUIElementCreateApplication(12)
    let file = AXUIElementCreateApplication(13)

    func read(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        if name == kAXMenuBarAttribute {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            reads.append(pid)
        }
        if name == failedAttribute, name != kAXTitleAttribute || element == apple { return nil }
        switch name {
        case kAXMenuBarAttribute: return menuBar
        case kAXChildrenAttribute: return (empty ? [] : [apple, app, file]) as CFArray
        case kAXTitleAttribute:
            return (element == apple ? "Apple" : element == app ? title : "File") as CFString
        default: return nil
        }
    }
}

@Test(arguments: [kAXMenuBarAttribute, kAXChildrenAttribute, kAXTitleAttribute])
@MainActor func menuReadFailureKeepsCompleteMenusAndRetries(
    attribute: String
) async throws {
    let source = MenuReadFixture()
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read)
    menu.read(MenuApplication(pid: 100))
    let apple = try #require(menu.appleMenu)
    let items = menu.items
    source.failedAttribute = attribute
    menu.refresh()
    #expect(menu.appleMenu == apple)
    #expect(menu.items == items)

    source.failedAttribute = nil
    source.title = "Recovered"
    await menu.retryTask?.value
    #expect(menu.appleMenu == apple)
    #expect(menu.items.map(\.title) == ["Recovered", "File"])
    #expect(source.reads == [100, 100, 100])
}

@Test @MainActor func menuRecoversWhenItsFirstReadFails() async {
    let source = MenuReadFixture()
    source.failedAttribute = kAXMenuBarAttribute
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read)
    menu.read(MenuApplication(pid: 100))
    #expect(menu.items.isEmpty)
    source.failedAttribute = nil
    await menu.retryTask?.value
    #expect(menu.appleMenu?.title == "Apple")
    #expect(menu.items.map(\.title) == ["First", "File"])
}

@Test(arguments: [false, true])
@MainActor func switchingAppsCancelsThePreviousMenuRetry(secondReadFails: Bool) async {
    let source = MenuReadFixture()
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read)
    menu.read(MenuApplication(pid: 100))
    source.failedAttribute = kAXMenuBarAttribute
    menu.refresh()
    let previousRetry = menu.retryTask
    source.failedAttribute = secondReadFails ? kAXMenuBarAttribute : nil
    source.title = "Second"
    menu.read(MenuApplication(pid: 200))
    source.failedAttribute = nil
    await previousRetry?.value
    await menu.retryTask?.value
    #expect(menu.items.map(\.title) == ["Second", "File"])
    #expect(source.reads == (secondReadFails ? [100, 100, 200, 200] : [100, 100, 200]))
}

@Test @MainActor func disablingMenusCancelsRecoveryAndClearsThem() async {
    let source = MenuReadFixture()
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read)
    menu.read(MenuApplication(pid: 100))
    source.failedAttribute = kAXMenuBarAttribute
    menu.refresh()
    let retry = menu.retryTask
    menu.read(nil)
    source.failedAttribute = nil
    await retry?.value
    #expect(menu.appleMenu == nil)
    #expect(menu.items.isEmpty)
    #expect(source.reads == [100, 100])
    #expect(menu.retryTask == nil)
}

@Test @MainActor func revokingAccessDuringMenuRecoveryClearsTheMenus() async {
    let source = MenuReadFixture()
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read)
    menu.read(MenuApplication(pid: 100))
    source.failedAttribute = kAXMenuBarAttribute
    menu.refresh()
    source.trusted = false
    await menu.retryTask?.value
    #expect(!menu.isTrusted)
    #expect(menu.appleMenu == nil)
    #expect(menu.items.isEmpty)
    #expect(source.reads == [100, 100])
}

@Test @MainActor func aSuccessfulEmptyMenuReadClearsPreviousMenusWithoutRetrying() {
    let source = MenuReadFixture()
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read)
    menu.read(MenuApplication(pid: 100))
    source.empty = true
    menu.refresh()
    #expect(menu.appleMenu == nil)
    #expect(menu.items.isEmpty)
    #expect(menu.retryTask == nil)
}

@Test @MainActor func menuRecoveryStopsAfterFourRetries() async {
    let source = MenuReadFixture()
    source.failedAttribute = kAXMenuBarAttribute
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read)
    menu.read(MenuApplication(pid: 100))
    await menu.retryTask?.value
    #expect(source.reads == [100, 100, 100, 100, 100])
}

@Test @MainActor func appleMenuKeepsItsIconWhenTheSourceAppChanges() throws {
    let appMenu = AppMenu()
    func image(title: String, pid: pid_t) throws -> CGImage {
        let item = AppMenuItem(title: title, element: AXUIElementCreateApplication(pid))
        let renderer = ImageRenderer(content: AppMenuView(appMenu: appMenu, items: [item], isAppleMenu: true,
            appearance: WidgetAppearance(WidgetStyle(), defaults: WidgetStyle()), padding: EdgeInsets(), requestAccess: {}))
        return try #require(renderer.cgImage)
    }
    let first = try image(title: "Apple", pid: 1)
    let second = try image(title: "Another app's Apple menu", pid: 2)
    #expect(first.width == second.width)
    #expect(first.height == second.height)
    #expect(first.dataProvider?.data == second.dataProvider?.data)
}

@Test @MainActor func appMenuReportsExpansionAndReturnsToItsCollapsedWidth() async throws {
    let source = MenuReadFixture()
    let menu = AppMenu(checkAccess: { source.trusted }, readAttribute: source.read)
    menu.read(MenuApplication(pid: 100))
    var expanded: Bool?
    func content(hovering: Bool) -> AppMenuView {
        AppMenuView(appMenu: menu, items: menu.items, expandOnHover: true, hovering: hovering,
                    appearance: WidgetAppearance(WidgetStyle(), defaults: WidgetStyle()),
                    padding: EdgeInsets(), requestAccess: {}) { expanded = $0 }
    }
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 40),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: content(hovering: false))
    window.contentView = host
    var widths: [CGFloat] = []
    for hovering in [false, true, false] {
        host.rootView = content(hovering: hovering)
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if expanded == hovering { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(expanded == hovering)
        widths.append(host.fittingSize.width)
    }
    #expect(widths[1] > widths[0])
    #expect(abs(widths[2] - widths[0]) < 0.5)
    #expect(!window.isVisible)
}

/// Actual AppKit/SwiftUI rendering, in a window that is never ordered onto the user's screen.
@MainActor final class PresentationHostingView: NSHostingView<AnyView> {
    private(set) var layoutCalls = 0
    override func layout() { layoutCalls += 1; super.layout() }
}

@MainActor final class OffscreenBar {
    let panel: BarPanel
    let host: PresentationHostingView
    let store: BarStore
    let backingScale: CGFloat
    private let ownsStore: Bool
    let display: BarDisplay

    init(configuration: Configuration, display: BarDisplay, width: CGFloat, workspaces: [Workspace] = [],
         backingScale: CGFloat = 2, sharedStore: BarStore? = nil) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        self.backingScale = backingScale
        self.display = display
        ownsStore = sharedStore == nil
        store = sharedStore ?? BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        if sharedStore == nil {
            store.configuration = configuration
            store.workspaceStore.workspaces = workspaces
            store.preparePresentations()
        }
        let geometry = configuration.barGeometry(for: display)
        let top = (NSScreen.main?.frame.maxY ?? 900) - 40
        panel = BarPanel(contentRect: CGRect(x: 0, y: top - geometry.inputHeight, width: width, height: geometry.inputHeight),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.barGeometry = geometry
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        host = PresentationHostingView(rootView: AnyView(BarView(store: store, display: display, nativeDecorations: true)
            .frame(width: width, height: geometry.inputHeight)
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, backingScale)
            .transaction { $0.disablesAnimations = true; $0.animation = nil }))
        host.frame = CGRect(origin: .zero, size: panel.frame.size)
        host.sizingOptions = []
        panel.contentView = host
    }

    func settle() async {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func refreshGeometry() {
        guard let configuration = store.configuration else { return }
        let geometry = configuration.barGeometry(for: display)
        let top = panel.frame.maxY
        panel.barGeometry = geometry
        panel.setFrame(CGRect(x: panel.frame.minX, y: top - geometry.inputHeight, width: panel.frame.width,
                              height: geometry.inputHeight), display: false)
        host.rootView = AnyView(BarView(store: store, display: display, nativeDecorations: true)
            .frame(width: panel.frame.width, height: geometry.inputHeight)
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, backingScale)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
    }

    func bitmap(scale: CGFloat? = nil, name: String? = nil) throws -> NSBitmapImageRep {
        let scale = scale ?? backingScale
        let size = panel.drawingFrame.size
        func blank(_ size: CGSize) throws -> NSBitmapImageRep {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
                pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size
            return bitmap
        }
        let bitmap = try blank(size)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        context.interpolationQuality = .none
        let bar = try blank(host.bounds.size)
        host.cacheDisplay(in: host.bounds, to: bar)
        context.draw(try #require(bar.cgImage), in: CGRect(x: 0, y: size.height - host.bounds.height,
            width: size.width, height: host.bounds.height))
        if let decoration = panel.decorationPanel?.contentView {
            decoration.layoutSubtreeIfNeeded()
            let layer = try blank(decoration.bounds.size)
            decoration.cacheDisplay(in: decoration.bounds, to: layer)
            context.draw(try #require(layer.cgImage), in: CGRect(origin: .zero, size: size))
        }
        if let name, let output = ProcessInfo.processInfo.environment["STABLEBAR_RENDER_OUTPUT"] {
            let directory = URL(filePath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "\(name).png"))
        }
        return bitmap
    }

    func anchors(_ id: String) -> [NSView] {
        func find(_ view: NSView) -> [NSView] {
            (view.identifier?.rawValue == id ? [view] : []) + view.subviews.flatMap(find)
        }
        return find(host)
    }

    func close() { if ownsStore { store.stop() }; panel.contentView = nil; panel.close() }

}

private func indicatorConfiguration(gap: Int, scale: Double = 1, placement: String = "belowBar", cellHeight: Int = 22) throws -> Configuration {
    try JSONDecoder().decode(Configuration.self, from: Data(##"""
    {"bar":{"height":38,"inset":12,"spacing":0,"displayScale":{"external":\##(scale)},"style":{"background":"#101010"}},
      "defaults":{"foreground":"#ffffff","fontSize":13,"paddingHorizontal":0,"paddingVertical":0},
      "widgets":[{"id":"spaces","type":"workspaces","position":"left","workspace":{
        "showEmpty":true,"showApps":false,"indicator":"underline","style":{"height":\##(cellHeight),"width":36},
        "indicatorStyle":{"placement":"\##(placement)","height":2,"background":"#ff00ff","offsetY":\##(gap)}
      }}]}
    """##.utf8))
}

@Test @MainActor func nativeBelowBarRenderingHasExactGapAndHeightWithStableLabelsAndClickThrough() async throws {
    let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
    for scale in [1.0, 1.5, 2.0] {
        for gap in [0, 3] {
            let configuration = try indicatorConfiguration(gap: gap, scale: scale)
            let fixture = OffscreenBar(configuration: configuration, display: display, width: 300, workspaces: [
                Workspace(name: "1", isFocused: true, isVisible: true, monitor: 1),
                Workspace(name: "2", isFocused: false, isVisible: false, monitor: 1)
            ])
            defer { fixture.close() }
            await fixture.settle()
            let geometry = configuration.barGeometry(for: display)
            #expect(abs(fixture.panel.frame.height - 38 * scale) < 0.01)
            #expect(fixture.panel.drawingFrame.height == geometry.panelHeight)
            let bitmap = try fixture.bitmap(name: "underline-gap\(gap)-scale\(scale)")
            let anchors = fixture.anchors("spaces")
            try #require(anchors.count == 1) // the measuring copy emits no popup anchor
            let bounds = anchors[0].convert(anchors[0].bounds, to: fixture.host)
            #expect(abs(bounds.minX - 12 * scale) < 0.01)
            #expect(abs(bounds.width - 78 * scale) < 0.01)
            var pixels: [(Int, Int)] = []
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > 0.9 && color.blueComponent > 0.9 && color.greenComponent < 0.1 { pixels.append((x, y)) }
                }
            }
            #expect(!pixels.isEmpty)
            #expect(pixels.map(\.1).min() == Int((38 + CGFloat(gap)) * scale * 2))
            #expect(pixels.map(\.1).max() == Int((40 + CGFloat(gap)) * scale * 2) - 1)
            #expect(pixels.map(\.0).min() == Int(12 * scale * 2))
            #expect(pixels.map(\.0).max() == Int(48 * scale * 2) - 1)
            // The actual native decoration window always ignores input; the bar's own
            // strip-sized window still receives its background menu and widget events.
            let decoration = try #require(fixture.panel.decorationPanel)
            #expect(decoration.ignoresMouseEvents)
            #expect(!fixture.panel.ignoresMouseEvents)
            #expect(decoration.frame == fixture.panel.drawingFrame)
            #expect(!fixture.panel.frame.contains(CGPoint(x: decoration.frame.midX, y: decoration.frame.minY + 0.25)))
            #expect(!fixture.panel.isVisible && !decoration.isVisible)
            let before = fixture.panel.frame
            fixture.store.workspaceStore.workspaces = [
                Workspace(name: "1", isFocused: false, isVisible: false, monitor: 1),
                Workspace(name: "2", isFocused: true, isVisible: true, monitor: 1)
            ]
            await fixture.settle()
            #expect(fixture.panel.frame == before)
            #expect(anchors[0].convert(anchors[0].bounds, to: fixture.host) == bounds)
        }
    }
}

@Test func decorationBoundsReserveNestedStateCombinationsAndRespectMarginsAndViewports() throws {
    let style = try JSONDecoder().decode(WidgetStyle.self, from: Data(#"""
    {"placement":"cell","height":2,"states":{
      "focused":{"placement":"belowBar","height":3},
      "mode":{"offsetY":4,"states":{"mode.command":{"height":5}}}}}
    """#.utf8))
    #expect(style.maximumOutsideExtent == 9)
    let geometry = BarGeometry(layoutHeight: 38, margin: 3, outsideExtent: 9)
    #expect(geometry.panelHeight == 44)
    #expect(geometry.visibleRect(width: 300) == CGRect(x: 3, y: 3, width: 294, height: 32))
    let rect = belowBarIndicatorRect(cell: CGRect(x: -10, y: 5, width: 50, height: 22),
        widget: CGRect(x: -20, y: 0, width: 300, height: 38), viewport: CGRect(x: 12, y: 0, width: 25, height: 38),
        visibleBar: CGRect(x: 0, y: 0, width: 300, height: 38),
        style: WidgetStyle(height: 2, offsetY: 3), scale: 1, pixelsPerPoint: 2)
    #expect(rect == CGRect(x: 12, y: 41, width: 25, height: 2))
    let offscreen = belowBarIndicatorRect(cell: CGRect(x: -50, y: 5, width: 20, height: 22),
        widget: CGRect(x: -60, y: 0, width: 300, height: 38), viewport: CGRect(x: 12, y: 0, width: 25, height: 38),
        visibleBar: CGRect(x: 0, y: 0, width: 300, height: 38), style: WidgetStyle(), scale: 1, pixelsPerPoint: 1)
    #expect(offscreen == nil)
    #expect(popupAttachmentTop(anchor: CGRect(x: -1000, y: 800, width: 40, height: 22),
        window: CGRect(x: -1500, y: 780, width: 1512, height: 44), geometry: geometry) == 780)
    #expect(popupAttachmentTop(anchor: CGRect(x: 100, y: 1700, width: 40, height: 22),
        window: CGRect(x: 0, y: 1680, width: 2560, height: 44), geometry: geometry) == 1680)
    #expect(popupAttachmentTop(anchor: CGRect(x: 100, y: 1690, width: 40, height: 22),
        window: CGRect(x: 0, y: 1682, width: 2560, height: 38),
        geometry: BarGeometry(layoutHeight: 38, margin: 3, outsideExtent: 0)) == 1685)
}

@Test @MainActor func nativeConstrainedWorkspaceClipsItsDecorationAndScrollingRemovesOffscreenSelection() async throws {
    let json = ##"""
    {"bar":{"height":38,"inset":12,"spacing":4,"style":{"background":"#101010"}},
     "defaults":{"foreground":"#ffffff","paddingHorizontal":0,"paddingVertical":0},"widgets":[
      {"id":"spaces","type":"workspaces","position":"left","overflow":"never","workspace":{
        "showEmpty":true,"showApps":false,"indicator":"underline","style":{"width":36},
        "indicatorStyle":{"placement":"belowBar","height":2,"background":"#ff00ff"}}},
      {"id":"extra","type":"text","text":"A long optional label that must overflow","position":"right"}]}
    """##
    let config = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
    let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
    var workspaces: [Workspace] = []
    for index in 1...9 {
        workspaces.append(Workspace(name: String(index), isFocused: index == 1, isVisible: index == 1, monitor: 1))
    }
    let fixture = OffscreenBar(configuration: config, display: display, width: 80, workspaces: workspaces)
    defer { fixture.close() }
    await fixture.settle()
    func scrolls(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
    }
    let scroll = try #require(scrolls(fixture.host).first)
    #expect(fixture.anchors("spaces").count == 1)
    #expect(fixture.anchors("extra").isEmpty) // overflowed widgets have no visible anchor
    let before = try fixture.bitmap(name: "constrained-before-scroll")
    func magentaX(_ bitmap: NSBitmapImageRep) -> [Int] {
        (0..<bitmap.pixelsWide).filter { x in
            guard let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 2)?.usingColorSpace(.deviceRGB) else { return false }
            return color.redComponent > 0.9 && color.blueComponent > 0.9 && color.greenComponent < 0.1
        }
    }
    #expect(!magentaX(before).isEmpty)
    let workspaceRegion = scroll.convert(scroll.bounds, to: fixture.host)
    #expect(workspaceRegion.width < 36)
    #expect(magentaX(before).max() == Int(workspaceRegion.maxX * 2) - 1)
    scroll.contentView.scroll(to: CGPoint(x: 100, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    await fixture.settle()
    let after = try fixture.bitmap(name: "constrained-after-scroll")
    #expect(magentaX(after).isEmpty)
    #expect(abs(fixture.panel.frame.height - 38) < 0.01)
    #expect(fixture.panel.drawingFrame.height == 40)
}

@Test @MainActor func nativeOutlineStaysInsideTheVisibleStripAndBottomDefaultIsUnchanged() async throws {
    for edges in ["bottom", "all"] {
        let json = ##"{"bar":{"height":38,"margin":3,"style":{"background":"#101010","borderColor":"#ff00ff","borderWidth":1,"borderEdges":"\##(edges)","cornerRadius":4}},"widgets":[]}"##
        let config = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
        let fixture = OffscreenBar(configuration: config, display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 100)
        defer { fixture.close() }
        await fixture.settle()
        let bitmap = try fixture.bitmap(name: "border-\(edges)")
        func isBorder(_ x: Int, _ y: Int) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.redComponent > 0.8 && color.blueComponent > 0.8 && color.greenComponent < 0.2 && color.alphaComponent > 0.8
        }
        #expect(isBorder(100, 69))
        #expect(isBorder(100, 6) == (edges == "all"))
        #expect(isBorder(6, 38) == (edges == "all"))
        #expect(isBorder(193, 38) == (edges == "all"))
        #expect(!isBorder(100, 5))
        #expect(!isBorder(100, 70))
        #expect(fixture.panel.frame.height == 38)
    }
}

@Test @MainActor func fractionalScaleOnOneXDisplayReservesBothPixelRoundingSteps() async throws {
    let config = try JSONDecoder().decode(Configuration.self, from: Data(##"""
    {"bar":{"height":25,"displayScale":{"external":1.5},"style":{"background":"#101010"}},
      "defaults":{"paddingHorizontal":0,"paddingVertical":0},"widgets":[
       {"id":"spaces","type":"workspaces","position":"left","workspace":{"showApps":false,"indicator":"underline",
        "indicatorStyle":{"placement":"belowBar","height":1,"background":"#ff00ff"}}}]}
    """##.utf8))
    let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
    let fixture = OffscreenBar(configuration: config, display: display, width: 200,
        workspaces: [Workspace(name: "1", isFocused: true, isVisible: true, monitor: 1)], backingScale: 1)
    defer { fixture.close() }
    await fixture.settle()
    #expect(config.barGeometry(for: display).panelHeight == 40)
    let image = try fixture.bitmap(name: "underline-half-pixel-one-x")
    var rows = Set<Int>()
    for y in 0..<image.pixelsHigh {
        for x in 0..<image.pixelsWide {
            if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
               color.redComponent > 0.9 && color.blueComponent > 0.9 && color.greenComponent < 0.1 { rows.insert(y) }
        }
    }
    #expect(rows == [38, 39])
    #expect(fixture.panel.decorationPanel?.ignoresMouseEvents == true)
}
