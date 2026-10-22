import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import StableBar

@Test func scriptOutputSupportsTextAndRichUpdates() throws {
    let plain = try ScriptOutput.read(Data("  1.42\n".utf8))
    #expect(plain.text == "1.42")
    let rich = try ScriptOutput.read(Data(##"{"text":"Building","icon":"hammer","color":"#f7821b80","tooltip":"App build"}"##.utf8))
    #expect(rich.text == "Building")
    #expect(rich.icon == "hammer")
    #expect(rich.color == HexColor(0xf7821b80))
    #expect(rich.tooltip == "App build")
    let popup = try ScriptOutput.read(Data(#"{"text":"30%","value":0.3,"fields":{"usage":"30%"},"lists":{"processes":[{"name":"Window Server","cpu":"90.1%","memory":"108 MB"}]}}"#.utf8))
    #expect(popup.fields?["usage"] == "30%")
    #expect(popup.lists?["processes"]?.first?["name"] == "Window Server")
    #expect(popup.value == 0.3)
}

@Test func brokenRichOutputIsNotRenderedAsText() {
    #expect(throws: DecodingError.self) {
        try ScriptOutput.read(Data(#"{"text":"Building","color":"orange"}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try ScriptOutput.read(Data(#"{"text":"30%","lists":{"processes":[{"cpu":30}]}}"#.utf8))
    }
}

@Test func namedGraphsKeepOnlyTheLatestSixtySamples() throws {
    let values = (0..<80).map { Double($0) / 100 }
    let data = try JSONSerialization.data(withJSONObject: ["text": "History", "series": ["cpu": values]])
    let output = try ScriptOutput.read(data)
    #expect(output.series?["cpu"] == Array(values.suffix(60)))
}

@Test func progressClipsNumbersBeforeDrawingAndConvertingToPercent() {
    #expect(progressFraction(0.4) == 0.4)
    #expect(progressFraction(-10) == 0)
    #expect(progressFraction(1e300) == 1)
    #expect(progressFraction(.infinity) == 0)
    #expect(progressFraction(.nan) == 0)
}

@Test func triggerArgumentsPreserveLiteralValuesWithoutShellExpansion() throws {
    let command = try LaunchCommand(arguments: ["--trigger", "build", "INFO=hello = 'world' $(date)", "EMPTY="])
    guard case let .trigger(name, environment) = command else {
        Issue.record("Expected an event command.")
        return
    }
    #expect(name == "build")
    #expect(environment == ["INFO": "hello = 'world' $(date)", "EMPTY": ""])
    for arguments in [["--trigger"], ["--trigger", "build", "INFO"], ["--trigger", "build", "=value"], ["--unknown"]] {
        #expect(throws: CommandFailure.self) { try LaunchCommand(arguments: arguments) }
    }
}

@Test func popupStylesInheritWidgetOverridesAndGlobalTheme() {
    let defaults = WidgetStyle(foreground: HexColor(0xeeeeeeff), background: .color(HexColor(0x222222ff)),
                               fontName: "Helvetica", fontSize: 12, paddingHorizontal: 7, width: 80)
    let widget = WidgetStyle(background: .color(HexColor(0x333333ff)), fontWeight: "bold", width: 85)
    let popup = WidgetStyle(fontSize: 18, paddingHorizontal: 16, width: 380)
    let style = popup.inheriting(widget.inheriting(defaults))
    #expect(style.foreground == defaults.foreground)
    #expect(style.background == widget.background)
    #expect(style.fontName == "Helvetica")
    #expect(style.fontWeight == "bold")
    #expect(style.fontSize == 18)
    #expect(style.paddingHorizontal == 16)
    #expect(style.width == 380)
}

@Test @MainActor func popupObservesScriptFieldsAndHistory() async throws {
    let widget = try JSONDecoder().decode(WidgetConfiguration.self, from: Data(#"{"id":"cpu","type":"script","command":"echo","position":"right","popup":{"height":200,"style":{},"layout":{"type":"field","field":"usage"}}}"#.utf8))
    let store = BarStore()
    let script = ScriptWidget()
    store.scripts[widget.id] = script
    let view = PopupView(popup: widget.popup!, style: WidgetStyle(), store: store, widget: widget)
    await confirmation("Popup observes new fields") { changed in
        withObservationTracking { _ = view.body } onChange: { changed() }
        script.output = ScriptOutput(text: "30%", fields: ["usage": "30%"])
    }
    await confirmation("Popup observes new graph samples") { changed in
        withObservationTracking { _ = view.body } onChange: { changed() }
        script.samples.append(0.3)
    }
}

@Test(arguments: [120.0, 600.0]) @MainActor
func popupFoldKeepsTheScrollViewportAndPosition(documentHeight: Double) {
    let size = NSSize(width: 360, height: 240)
    let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: documentHeight))
    let reveal = PopupRevealView(content: scroll, size: size)
    scroll.tile()
    if documentHeight > size.height {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
    }
    let viewport = scroll.contentView.bounds
    let visibleDocument = scroll.documentVisibleRect
    #expect(viewport.height == size.height)
    #expect(reveal.clipsToBounds)

    for height in [1.0, 60, 120, 240, 120, 60, 1, 240] {
        reveal.setFrameSize(NSSize(width: size.width, height: height))
        scroll.layoutSubtreeIfNeeded()
        #expect(scroll.frame.size == size)
        #expect(scroll.frame.maxY == reveal.bounds.maxY)
        #expect(scroll.contentView.bounds == viewport)
        #expect(scroll.documentVisibleRect == visibleDocument)
    }
}

@Test func duplicateIdsCannotBreakWidgetIdentity() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Configuration.self, from: Data(#"{"widgets":[{"id":"clock","type":"clock","position":"left"},{"id":"clock","type":"clock","position":"right"}]}"#.utf8))
    }
}

@Test func zeroIntervalCannotStartABusyLoop() {
    #expect(throws: CommandFailure.self) {
        try JSONDecoder().decode(Configuration.self, from: Data(#"{"widgets":[{"id":"test","type":"script","position":"left","command":"date","interval":0}]}"#.utf8))
    }
}

@Test func commandOutputLargerThanAPipeBufferCompletes() async throws {
    let data = try await runCommand("/usr/bin/head", arguments: ["-c", "131072", "/dev/zero"])
    #expect(data.count == 131072)
}

@Test func commandFailureIncludesStderr() async {
    do {
        _ = try await runCommand("/bin/zsh", arguments: ["-c", "printf 'widget failed' >&2; exit 3"])
        Issue.record("The failed command was accepted.")
    } catch {
        #expect(error.localizedDescription == "widget failed")
    }
}

@Test func cancellingAWidgetStopsItsRunningCommand() async throws {
    let task = Task { try await runCommand("/bin/sleep", arguments: ["5"]) }
    try await Task.sleep(for: .milliseconds(100))
    let start = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(2))
}

@Test func workspaceSnapshotKeepsMonitorFocusAndDeduplicatesAppWindows() throws {
    let spaces = Data(#"[{"workspace":"10","workspace-is-focused":false,"workspace-is-visible":false,"monitor-appkit-nsscreen-screens-id":2},{"workspace":"2","workspace-is-focused":false,"workspace-is-visible":true,"monitor-appkit-nsscreen-screens-id":2},{"workspace":"1","workspace-is-focused":true,"workspace-is-visible":true,"monitor-appkit-nsscreen-screens-id":1}]"#.utf8)
    let windows = Data(#"[{"workspace":"1","app-name":"Finder","app-bundle-id":"com.apple.finder","window-id":1,"window-title":"Window 1"},{"workspace":"1","app-name":"Finder","app-bundle-id":"com.apple.finder","window-id":2,"window-title":"Window 2"},{"workspace":"2","app-name":"Finder","app-bundle-id":"com.apple.finder","window-id":3,"window-title":"Window 3"}]"#.utf8)
    let snapshot = try workspaceSnapshot(workspaces: spaces, windows: windows)
    #expect(snapshot.map(\.name) == ["1", "2", "10"])
    #expect(snapshot[0].isFocused)
    #expect(!snapshot[1].isFocused)
    #expect(snapshot[1].isVisible)
    #expect(snapshot[1].monitor == 2)
    #expect(snapshot[0].windows.map(\.id) == [1, 2])
    #expect(snapshot[0].windows.map(\.title) == ["Window 1", "Window 2"])
    #expect(snapshot[1].windows.map(\.id) == [3])
    #expect(snapshot[2].windows.isEmpty)
    #expect(snapshot[0].apps.count == 1)
    #expect(snapshot[1].apps.count == 1)
    #expect(snapshot[2].apps.isEmpty)
}

@Test func yabaiSnapshotMapsDisplaysAndAppWindowsToWorkspaces() throws {
    let spaces = Data(#"[{"index":10,"display":1,"has-focus":false,"is-visible":false},{"index":2,"display":1,"has-focus":true,"is-visible":true},{"index":1,"display":2,"has-focus":false,"is-visible":true}]"#.utf8)
    let windows = Data(#"[{"pid":41,"app":"Safari","space":1,"id":1,"title":"Window 1"},{"pid":42,"app":"Finder","space":1,"id":2,"title":"Window 2"},{"pid":43,"app":"Safari","space":1,"id":3,"title":"Window 3"},{"pid":41,"app":"Safari","space":2,"id":4,"title":"Window 4"}]"#.utf8)
    let displays = Data(#"[{"id":80,"index":1},{"id":90,"index":2}]"#.utf8)
    let snapshot = try yabaiSnapshot(spaces: spaces, windows: windows, displays: displays, screenIDs: [90, 80],
                                     bundleIDs: [41: "com.apple.Safari", 42: "com.apple.finder", 43: "com.apple.Safari"])
    #expect(snapshot.map(\.name) == ["1", "2", "10"])
    #expect(snapshot.map(\.monitor) == [1, 2, 2])
    #expect(snapshot[1].isFocused)
    #expect(snapshot[0].isVisible)
    #expect(snapshot[0].windows.map(\.id) == [1, 2, 3])
    #expect(snapshot[0].windows.map(\.title) == ["Window 1", "Window 2", "Window 3"])
    #expect(snapshot[0].windows.map(\.app.bundleID) == ["com.apple.Safari", "com.apple.finder", "com.apple.Safari"])
    #expect(snapshot[1].windows.map(\.id) == [4])
    #expect(snapshot[2].windows.isEmpty)
    #expect(snapshot[0].apps.map(\.bundleID) == ["com.apple.finder", "com.apple.Safari"])
    #expect(snapshot[1].apps.count == 1)
    #expect(snapshot[2].apps.isEmpty)
    let disconnected = try yabaiSnapshot(spaces: spaces, windows: windows, displays: displays, screenIDs: [90], bundleIDs: [:])
    #expect(disconnected.map(\.name) == ["1"])
    #expect(disconnected[0].apps.map(\.name) == ["Finder", "Safari"])
}

@Test func spacesSnapshotNumbersDesktopsAcrossDisplays() throws {
    func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    let displays = try plist([
        ["Display Identifier": "LEFT", "Current Space": ["ManagedSpaceID": 3, "type": 0],
         "Spaces": [["ManagedSpaceID": 1, "type": 0], ["ManagedSpaceID": 2, "type": 4], ["ManagedSpaceID": 3, "type": 0]]],
        ["Display Identifier": "GONE", "Current Space": ["ManagedSpaceID": 4, "type": 0], "Spaces": [["ManagedSpaceID": 4, "type": 0]]],
        ["Display Identifier": "RIGHT", "Current Space": ["ManagedSpaceID": 5, "type": 0], "Spaces": [["ManagedSpaceID": 5, "type": 0]]],
    ])
    let windows = try plist([
        ["kCGWindowNumber": 11, "kCGWindowOwnerPID": 41, "kCGWindowOwnerName": "Safari", "kCGWindowName": "Docs", "kCGWindowLayer": 0],
        ["kCGWindowNumber": 12, "kCGWindowOwnerPID": 42, "kCGWindowOwnerName": "Finder", "kCGWindowLayer": 0],
        ["kCGWindowNumber": 13, "kCGWindowOwnerPID": 41, "kCGWindowOwnerName": "Safari", "kCGWindowName": "Menu", "kCGWindowLayer": 101],
        ["kCGWindowNumber": 14, "kCGWindowOwnerPID": 43, "kCGWindowOwnerName": "Helper", "kCGWindowLayer": 0],
    ])
    let snapshot = try spacesSnapshot(displays: displays, windows: windows,
                                      windowSpaces: [11: [1], 12: [1, 5], 13: [1], 14: [3]], activeSpace: 5,
                                      screenUUIDs: ["RIGHT", "LEFT"], bundleIDs: [41: "com.apple.Safari", 42: "com.apple.finder"])
    #expect(snapshot.map(\.name) == ["1", "2", "4"])
    #expect(snapshot.map(\.monitor) == [2, 2, 1])
    #expect(snapshot.map(\.isVisible) == [false, true, true])
    #expect(snapshot.map(\.isFocused) == [false, false, true])
    #expect(snapshot[0].windows.map(\.id) == [11, 12])
    #expect(snapshot[0].windows.map(\.title) == ["Docs", ""])
    #expect(snapshot[0].apps.map(\.name) == ["Finder", "Safari"])
    #expect(snapshot[1].apps.isEmpty)
    #expect(snapshot[2].apps.map(\.bundleID) == ["com.apple.finder"])
}

@Test(arguments: [WorkspaceSource.aerospace, .yabai]) @MainActor
func workspaceWindowFocusUsesItsIDAndReportsFailure(source: WorkspaceSource) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appending(path: "window-manager")
    let log = directory.appending(path: "calls")
    try Data("""
    #!/bin/sh
    echo "$*" >> '\(log.path)'
    echo "Window no longer exists" >&2
    exit 1
    """.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let store = WorkspaceStore()
    store.source = source
    store.executablePath = { executable.path }
    defer { store.stop() }
    store.focus(WorkspaceWindow(id: 73, title: "Second document", app: WorkspaceApp(workspace: "2", name: "Finder", bundleID: "com.apple.finder")))
    for _ in 0..<100 {
        if store.error != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.error == "Window no longer exists")
    let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    #expect(calls.first == (source == .aerospace ? "focus --window-id 73" : "-m window --focus 73"))
}

@Test @MainActor func workspaceWindowTitlesUseTheConfiguredCharacterLimit() throws {
    let store = WorkspaceStore()
    let app = WorkspaceApp(workspace: "1", name: "Finder", bundleID: "com.apple.finder")
    store.workspaces = [Workspace(name: "1", isFocused: true, isVisible: true, monitor: 1,
                                 apps: [app], windows: [WorkspaceWindow(id: 1, title: "👨‍👩‍👧‍👦Résumé document", app: app)])]
    func width(_ title: String, length: Int) throws -> CGFloat {
        store.workspaces[0].windows = [WorkspaceWindow(id: 1, title: title, app: app)]
        let configuration = try JSONDecoder().decode(WorkspaceConfiguration.self, from: Data("""
        {"windows":true,"titleLength":\(length),"appGlyphs":{"*":"F"}}
        """.utf8))
        let view = WorkspaceView(workspaceStore: store, monitor: 1,
                                 appearance: WidgetAppearance(WidgetStyle(), defaults: WidgetStyle()),
                                 configuration: configuration, animation: WidgetAnimation(duration: 0))
        return try #require(ImageRenderer(content: view).nsImage).size.width
    }
    let shortened = try width("👨‍👩‍👧‍👦Résumé document", length: 4)
    #expect(shortened == (try width("👨‍👩‍👧‍👦Rés", length: 20)))
    #expect(shortened < (try width("👨‍👩‍👧‍👦Résumé document", length: 20)))
    #expect(try width("👨‍👩‍👧‍👦Résumé document", length: 0) < shortened)
}

@Test @MainActor func displayedWorkspacesKeepEmptyVisibleSpacesOnTheirMonitor() {
    let workspaceStore = WorkspaceStore()
    workspaceStore.workspaces = [
        Workspace(name: "1", isFocused: false, isVisible: false, monitor: 1,
                  apps: [WorkspaceApp(workspace: "1", name: "Finder", bundleID: "com.apple.finder")]),
        Workspace(name: "2", isFocused: false, isVisible: false, monitor: 1),
        Workspace(name: "3", isFocused: true, isVisible: true, monitor: 1),
        Workspace(name: "4", isFocused: false, isVisible: true, monitor: 2)
    ]
    #expect(workspaceStore.workspaces(on: 1, showEmpty: false).map(\.name) == ["1", "3"])
    #expect(workspaceStore.workspaces(on: 1, showEmpty: true).map(\.name) == ["1", "2", "3"])
    #expect(workspaceStore.workspaces(on: 2, showEmpty: false).map(\.name) == ["4"])
    #expect(workspaceStore.workspaces(on: 3, showEmpty: false).isEmpty)

    workspaceStore.workspaces[2] = Workspace(name: "3", isFocused: false, isVisible: false, monitor: 1)
    #expect(workspaceStore.workspaces(on: 1, showEmpty: false).map(\.name) == ["1"])
}

@Test @MainActor func workspaceRowGrowsWhenAnEmptyWorkspaceAppears() throws {
    let workspaceStore = WorkspaceStore()
    workspaceStore.workspaces = [
        Workspace(name: "1", isFocused: false, isVisible: false, monitor: 1,
                  apps: [WorkspaceApp(workspace: "1", name: "Finder", bundleID: "com.apple.finder")]),
        Workspace(name: "2", isFocused: true, isVisible: true, monitor: 1,
                  apps: [WorkspaceApp(workspace: "2", name: "Finder", bundleID: "com.apple.finder")])
    ]
    let view = WorkspaceView(workspaceStore: workspaceStore, monitor: 1,
                             appearance: WidgetAppearance(WidgetStyle(), defaults: WidgetStyle()), animation: WidgetAnimation(duration: 0))
    let initialWidth = try #require(ImageRenderer(content: view).nsImage).size.width
    workspaceStore.workspaces[1] = Workspace(name: "2", isFocused: false, isVisible: false, monitor: 1,
                                       apps: workspaceStore.workspaces[1].apps)
    workspaceStore.workspaces.append(Workspace(name: "3", isFocused: true, isVisible: true, monitor: 1))
    let expandedWidth = try #require(ImageRenderer(content: view).nsImage).size.width
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: initialWidth, height: nil)
    #expect(expandedWidth > initialWidth)
    #expect(try #require(renderer.nsImage).size.width == expandedWidth)
}

@Test func appGlyphsMatchExactKeysThenTheLongestPrefixThenTheFallback() {
    let glyphs = ["com.apple.finder": ":finder:", "Adobe Photoshop": ":photoshop:", "Adobe*": ":adobe:",
                  "Adobe Photoshop*": ":photoshop_versions:", "*": ":default:"]
    func glyph(_ name: String, _ bundleID: String) -> String? {
        appGlyph(for: WorkspaceApp(workspace: "1", name: name, bundleID: bundleID), in: glyphs)
    }
    #expect(glyph("Finder", "com.apple.finder") == ":finder:")
    #expect(glyph("Adobe Photoshop", "com.adobe.Photoshop") == ":photoshop:")
    #expect(glyph("Adobe Photoshop 2026", "com.adobe.Photoshop.2026") == ":photoshop_versions:")
    #expect(glyph("Adobe Bridge 2026", "com.adobe.bridge14") == ":adobe:")
    #expect(glyph("Safari", "com.apple.Safari") == ":default:")
    #expect(appGlyph(for: WorkspaceApp(workspace: "1", name: "Safari", bundleID: "com.apple.Safari"), in: ["Adobe*": ":adobe:"]) == nil)
}

@Test @MainActor func nativeWorkspaceIconsKeepTheirImageIdentityAcrossRedraws() throws {
    var loads: [String] = []
    let icons = WorkspaceAppIcons { bundleID in
        loads.append(bundleID)
        return NSImage(size: NSSize(width: 32, height: 32))
    }
    let finder = try #require(icons.image(for: "com.apple.finder"))
    let safari = try #require(icons.image(for: "com.apple.Safari"))
    for _ in 0..<10 {
        let redraw = try #require(icons.image(for: "com.apple.finder"))
        #expect(Image(nsImage: finder) == Image(nsImage: redraw))
        #expect(icons.image(for: "com.apple.Safari") === safari)
    }
    #expect(loads == ["com.apple.finder", "com.apple.Safari"])
    #expect(finder !== safari)
}

@Test @MainActor func missingWorkspaceIconsRetryWhenAnAppBecomesAvailable() throws {
    var available = false
    let icons = WorkspaceAppIcons { _ in
        available ? NSImage(size: NSSize(width: 32, height: 32)) : nil
    }
    #expect(icons.image(for: "com.example.new-app") == nil)
    available = true
    let image = try #require(icons.image(for: "com.example.new-app"))
    #expect(icons.image(for: "com.example.new-app") === image)
}

@Test @MainActor func nativeWorkspaceIconsUseDetailedArtworkOnStandardAndRetinaDisplays() throws {
    let source = NSImage(size: NSSize(width: 32, height: 32))
    for (pixels, color) in [(32, NSColor.red), (256, NSColor.blue)] {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSRect(origin: .zero, size: bitmap.size).fill()
        NSGraphicsContext.restoreGraphicsState()
        source.addRepresentation(bitmap)
    }
    let icons = WorkspaceAppIcons { _ in source }
    for scale in [1.0, 2.0] {
        let size = NSSize(width: 20, height: 20)
        let image = try #require(icons.image(for: "com.example.multiresolution", size: size, scale: scale))
        let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(pixels.width == Int(20 * scale))
        #expect(pixels.height == Int(20 * scale))
        #expect(image.size == size)
        #expect(icons.image(for: "com.example.multiresolution", size: size, scale: scale) === image)
        let native = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(20 * scale), pixelsHigh: Int(20 * scale),
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        native.size = NSSize(width: 20, height: 20)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: native)
        image.draw(in: NSRect(origin: .zero, size: native.size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let nativeCenter = try #require(native.colorAt(x: native.pixelsWide / 2, y: native.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(nativeCenter.blueComponent > 0.9)
        #expect(nativeCenter.redComponent < 0.1)

        let renderer = ImageRenderer(content: Image(nsImage: image).resizable().interpolation(.high).frame(width: 20, height: 20))
        renderer.scale = scale
        let rendered = try #require(renderer.cgImage)
        #expect(rendered.width == Int(20 * scale))
        #expect(rendered.height == Int(20 * scale))
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        let center = try #require(bitmap.colorAt(x: rendered.width / 2, y: rendered.height / 2)?.usingColorSpace(.deviceRGB))
        #expect(center.blueComponent > 0.9)
        #expect(center.redComponent < 0.1)
    }
    #expect(source.size == NSSize(width: 32, height: 32))
}

@Test func notchGroupsStayOutsideAnOffCenterNotch() {
    let layout = BarLayout(inset: 12, spacing: 8, notchSpacing: 16, notch: 720...940)
    let x = layout.origins(width: 1728, sizes: [180, 260, 0, 200, 340])
    #expect(x[0] == 12)
    #expect(x[1] + 260 == 704)
    #expect(x[3] == 956)
    #expect(x[4] + 340 == 1716)
}

@Test func externalDisplayCentersTheCombinedGroupWithoutPhantomGaps() {
    let layout = BarLayout(inset: 12, spacing: 8, notchSpacing: 16, notch: nil)
    let x = layout.origins(width: 1920, sizes: [180, 260, 0, 100, 340])
    #expect(x[1] == 776)
    #expect(x[3] == 1044)
    #expect(x[1] == 1920 - (x[3] + 100))
    let musicOnly = layout.origins(width: 1920, sizes: [180, 260, 0, 0, 340])
    #expect(musicOnly[1] == 830)
    let center = layout.origins(width: 1920, sizes: [180, 0, 100, 0, 340])
    #expect(center[2] == 910)
}

@Test func displayFilteringTracksFocusAndScreenSelectors() throws {
    let laptop = BarDisplay(id: 2, isBuiltIn: true, isMain: false, notch: 650...870)
    let monitor = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
    #expect(DisplaySelection.active.includes(laptop, activeID: 2))
    #expect(!DisplaySelection.active.includes(laptop, activeID: 1))
    #expect(DisplaySelection.ids([1]).includes(monitor, activeID: 2))
    #expect(!DisplaySelection.ids([2]).includes(monitor, activeID: 2))
    #expect(DisplaySelection.notched.includes(laptop, activeID: 1))
    #expect(DisplaySelection.unnotched.includes(monitor, activeID: 1))
    #expect(DisplaySelection.external.includes(monitor, activeID: 2))
    let vertical = BarDisplay(id: 3, isBuiltIn: false, isMain: false, notch: nil, isPortrait: true)
    #expect(DisplaySelection.monitor.includes(monitor, activeID: 1))
    #expect(!DisplaySelection.monitor.includes(vertical, activeID: 1))
    #expect(DisplaySelection.vertical.includes(vertical, activeID: 1))
    let kinds = try JSONDecoder().decode(DisplaySelection.self, from: Data(#"["builtIn","vertical"]"#.utf8))
    #expect(kinds == .any([.builtIn, .vertical]))
    #expect([laptop, monitor, vertical].map { kinds.includes($0, activeID: 1) } == [true, false, true])
    #expect(ScreenKind.allCases.map { $0.shows(kinds, among: [laptop, monitor], activeID: 1) } == [true, false, true])
    #expect(!ScreenKind.vertical.shows(.main, among: [laptop, monitor, vertical], activeID: 1))
}

@Test func screenSetupsNameTheirScreensAndFiles() {
    let laptop = BarDisplay(id: 2, isBuiltIn: true, isMain: false, notch: nil)
    let monitor = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
    let vertical = BarDisplay(id: 3, isBuiltIn: false, isMain: false, notch: nil, isPortrait: true)
    #expect(ScreenSetup([laptop]).title == "Laptop only")
    #expect(ScreenSetup([vertical, monitor, laptop]).title == "Laptop + monitor + vertical monitor")
    #expect(ScreenSetup([vertical, monitor, laptop]).fileName == "setup-laptop+monitor+vertical.json")
    #expect(ScreenSetup([monitor, monitor]).title == "2 monitors")
    #expect(ScreenSetup(fileName: "setup-monitor+laptop.json") == ScreenSetup([laptop, monitor]))
    #expect(ScreenSetup(fileName: "setup-laptop+projector.json") == nil)
    #expect(ScreenSetup(fileName: "config.json") == nil)
}

@Test @MainActor func scriptRecoversAfterACommandFailure() async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let script = ScriptWidget()
    defer {
        script.stop()
        try? FileManager.default.removeItem(at: marker)
    }
    script.start(command: "if [ -f '\(marker.path)' ]; then echo Ready; else touch '\(marker.path)'; echo Offline >&2; exit 1; fi", interval: 0.02)
    for _ in 0..<100 {
        if script.output.text == "Ready" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "Ready")
    #expect(script.error == nil)
}

@Test @MainActor func invalidRuntimeIntervalKeepsTheLastGoodOutput() async throws {
    let script = ScriptWidget()
    script.output = ScriptOutput(text: "Ready")
    defer { script.stop() }
    script.start(command: "echo '{\"text\":\"Broken\",\"interval\":0}'", interval: 30)
    for _ in 0..<100 {
        if script.error != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "Ready")
    #expect(script.error == "A script interval must be greater than zero.")
}

@Test func setupKeepsUntouchedConfigurationByteForByte() throws {
    let data = Data(#"{ "widgets": [{"id":"time","type":"clock","position":"right","format":"HH.mm"}], "bar": {"height": 30} }"#.utf8)
    #expect(try SetupPreferences().applying(to: data, menuBarHeight: 38) == data)
}

@Test func setupChangesOnlySelectedSettingsAndPreservesCustomWidgets() throws {
    let data = Data(##"""
    {
      "bar": {"height": 48, "offset": 12, "notchSpacing": 20},
      "defaults": {"fontName": "Helvetica", "accent": "#ff8800", "paddingHorizontal": 15},
      "widgets": [
        {"id": "time", "type": "clock", "position": "right", "format": "HH.mm", "style": {"foreground": "#abcdef"}},
        {"id": "custom", "type": "script", "position": "left", "command": "~/my-widget.sh", "interval": 12,
         "layout": {"type": "field", "field": "text"}, "events": ["wake"]}
      ]
    }
    """##.utf8)
    let preferences = SetupPreferences(appearance: .dark, placement: .belowMenuBar, clock: .twelveHour)
    let updated = try preferences.applying(to: data, menuBarHeight: 38)
    let configuration = try JSONDecoder().decode(Configuration.self, from: updated)
    #expect(configuration.bar.offset == 38)
    #expect(configuration.bar.height == 48)
    #expect(configuration.bar.notchSpacing == 20)
    #expect(configuration.bar.appearance == .dark)
    #expect(configuration.defaults.foreground == nil)
    #expect(configuration.defaults.fontName == "Helvetica")
    #expect(configuration.defaults.accent == HexColor(0xff8800ff))
    #expect(configuration.widgets[0].content == .clock(format: "EEE d MMM  h:mm a"))
    #expect(configuration.widgets[0].style.foreground == HexColor(0xabcdefff))
    let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let result = try JSONSerialization.jsonObject(with: updated) as! [String: Any]
    #expect((original["widgets"] as! [NSDictionary])[1] == (result["widgets"] as! [NSDictionary])[1])
    let clockOnly = try SetupPreferences(clock: .twentyFourHour).applying(to: updated, menuBarHeight: 24)
    let clockResult = try JSONSerialization.jsonObject(with: clockOnly) as! [String: Any]
    #expect(clockResult["defaults"] as! NSDictionary == result["defaults"] as! NSDictionary)
    #expect(clockResult["bar"] as! NSDictionary == result["bar"] as! NSDictionary)
    let themed = try SetupPreferences(theme: .package(id: "slate", version: "1.0.0")).applying(to: updated, menuBarHeight: 24)
    let themedResult = try JSONSerialization.jsonObject(with: themed) as! [String: Any]
    #expect(themedResult["defaults"] as! NSDictionary == original["defaults"] as! NSDictionary)
    #expect(themedResult["theme"] as! NSDictionary == ["id": "slate", "version": "1.0.0"])
    let bundled = try SetupPreferences(appearance: .automatic, theme: .package(id: "paper", version: nil)).applying(to: updated, menuBarHeight: 24)
    let bundledResult = try JSONDecoder().decode([String: ConfigurationValue].self, from: bundled)
    #expect(bundledResult["theme"] == .object(["id": .string("paper")]))
    #expect(bundledResult["bar"] == .object(["height": .number(48), "offset": .number(38), "notchSpacing": .number(20), "appearance": .null]))
}

@Test(arguments: SetupPreferences.Preset.allCases)
func setupPresetsLoadWithTheBundledThemes(preset: SetupPreferences.Preset) throws {
    let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = repository.appending(path: "Resources/config.json")
    let data = try preset.preferences(sets: [.system, .meetings, .workspaces(.aerospace)])
        .applying(to: Data(contentsOf: url), menuBarHeight: 24)
    var loader = ConfigurationLoader()
    loader.themesDirectory = repository.appending(path: "Resources/themes")
    _ = try loader.load(url, data: data)
}

@Test func setupPlacesChosenWidgetSetsBesideTheAppAndClockAndKeepsWidgetsWithTheSameID() throws {
    let data = Data(#"""
    { "widgets": [
      {"id":"app","type":"activeApp","position":"left"},
      {"id":"time","type":"clock","position":"right"},
      {"id":"meeting","type":"text","position":"right","text":"Mine"}
    ] }
    """#.utf8)
    let updated = try SetupPreferences(widgetSets: [.meetings, .system, .workspaces(.yabai)]).applying(to: data, menuBarHeight: 24)
    let configuration = try JSONDecoder().decode(Configuration.self, from: updated)
    #expect(configuration.widgets.map(\.id) == ["workspaces", "app", "system-monitor", "time", "meeting"])
    #expect(configuration.widgets[4].content == .text("Mine"))
    #expect(configuration.workspaceSource == .yabai)
    let appended = try SetupPreferences(widgetSets: [.workspaces(.aerospace)])
        .applying(to: Data(#"{"widgets":[{"id":"time","type":"clock","position":"right"}]}"#.utf8), menuBarHeight: 24)
    let document = try JSONDecoder().decode([String: ConfigurationValue].self, from: appended)
    #expect(try document["widgets"]!.decoded([[String: ConfigurationValue]].self).map { $0["id"] } == [.string("time"), .string("workspaces")])
    #expect(document["workspaceSource"] == nil)
}

@Test func setupReenablesMatchingWidgetsAndKeepsConflictingIDs() throws {
    let data = Data(#"""
    {
      "providers":{"agenda":{"type":"calendar"}},
      "widgetOverrides":{"system-monitor":{"enabled":false,"style":{"fontSize":22}}},
      "widgets":[
        {"id":"system-monitor","type":"system","position":"left","enabled":false,"style":{"fontSize":18}},
        {"id":"meeting","type":"provider","provider":"agenda","position":"center","enabled":false},
        {"id":"workspaces","type":"text","text":"Mine","position":"right","enabled":false}
      ]
    }
    """#.utf8)
    let original = try JSONDecoder().decode(Configuration.self, from: data)
    #expect(SetupPreferences.WidgetSet.system.state(in: original) == .disabled)
    #expect(SetupPreferences.WidgetSet.meetings.state(in: original) == .disabled)
    #expect(SetupPreferences.WidgetSet.workspaces(.yabai).state(in: original) == .conflict)
    let updated = try SetupPreferences(widgetSets: [.system, .meetings, .workspaces(.yabai)])
        .applying(to: data, menuBarHeight: 24)
    let configuration = try JSONDecoder().decode(Configuration.self, from: updated)
    #expect(configuration.widgets.map(\.enabled) == [true, true, false])
    #expect(configuration.widgets.map(\.position) == [.left, .center, .right])
    #expect(configuration.widgets[0].style.fontSize == 22)
    #expect(configuration.widgets[1].content == .provider("agenda"))
    #expect(configuration.widgets[2].content == .text("Mine"))
    #expect(configuration.workspaceSource == .aerospace)
}

@Test func setupDefersMeetingsWithoutTurningOffExistingCalendars() throws {
    let preferences = SetupPreferences(widgetSets: [.meetings], deferMeetings: true)
    let new = try preferences.applying(to: Data(#"{"widgets":[]}"#.utf8), menuBarHeight: 24)
    let newConfiguration = try JSONDecoder().decode(Configuration.self, from: new)
    #expect(newConfiguration.widgets[0].id == "meeting")
    #expect(!newConfiguration.widgets[0].enabled)
    #expect(newConfiguration.activeProviders.isEmpty)
    for enabled in [true, false] {
        let data = Data(#"{"widgets":[{"id":"meeting","type":"calendar","position":"left","enabled":\#(enabled)}]}"#.utf8)
        let updated = try preferences.applying(to: data, menuBarHeight: 24)
        let configuration = try JSONDecoder().decode(Configuration.self, from: updated)
        #expect(configuration.widgets[0].enabled == enabled)
        #expect(configuration.widgets[0].position == .left)
    }
}

@Test func setupEnablesImportedWidgetsWithoutChangingTheirSource() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let module = directory.appending(path: "widgets.json")
    let moduleData = Data(#"{"widgets":[{"id":"meeting","type":"calendar","position":"left","enabled":false}]}"#.utf8)
    try moduleData.write(to: module)
    let root = directory.appending(path: "config.json")
    let data = Data(#"{"includes":["widgets.json"],"widgets":[]}"#.utf8)
    let updated = try SetupPreferences(widgetSets: [.meetings]).applying(to: data, menuBarHeight: 24, configurationURL: root)
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root, data: updated)
    #expect(configuration.widgets[0].enabled)
    #expect(configuration.widgets[0].position == .left)
    #expect(try Data(contentsOf: module) == moduleData)
}

@Test func setupKeepsAnActiveProfilesDisabledWidgetOverride() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "setup-disabled-profile.json")
    let data = Data(#"""
    {
      "widgets":[{"id":"system-monitor","type":"system","position":"right"}],
      "profiles":[{"name":"quiet","configuration":{"widgetOverrides":{"system-monitor":{"enabled":false}}}}]
    }
    """#.utf8)
    let updated = try SetupPreferences(widgetSets: [.system]).applying(to: data, menuBarHeight: 24, configurationURL: root)
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root, data: updated)
    #expect(!configuration.widgets[0].enabled)
    #expect(SetupPreferences.WidgetSet.system.state(in: configuration) == .disabled)
    #expect(loader.origins["widgets.system-monitor.enabled"]?.profile == "quiet")
}

@Test func setupRejectsInvalidConfigurationBeforeEditing() {
    #expect(throws: CommandFailure.self) {
        try SetupPreferences(appearance: .dark).applying(
            to: Data(#"{"widgets":[{"id":"custom","type":"script","position":"left","command":"date","interval":0}]}"#.utf8),
            menuBarHeight: 24)
    }
}

@Test func setupOverridesImportedAndTemplatedClocksWithoutChangingModules() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let module = directory.appending(path: "clocks.json")
    let moduleData = Data(#"{"widgets":[{"id":"imported","type":"clock","position":"right","format":"HH.mm"}]}"#.utf8)
    try moduleData.write(to: module)
    let root = directory.appending(path: "config.json")
    let data = Data(#"""
    {
      "includes": ["clocks.json"],
      "templates": {"clock": {"type":"clock", "position":"left"}},
      "widgets": [{"id":"local", "template":"clock"}],
      "widgetOverrides": {"imported": {"style": {"fontSize": 15}}}
    }
    """#.utf8)
    let updated = try SetupPreferences(clock: .twelveHour).applying(to: data, menuBarHeight: 24, configurationURL: root)
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root, data: updated)
    #expect(configuration.widgets.map(\.content) == [.clock(format: "EEE d MMM  h:mm a"), .clock(format: "EEE d MMM  h:mm a")])
    #expect(configuration.widgets[0].style.fontSize == 15)
    #expect(try Data(contentsOf: module) == moduleData)
    let document = try JSONDecoder().decode([String: ConfigurationValue].self, from: updated)
    #expect(document["includes"] == .array([.string("clocks.json")]))
    #expect(document["widgets"] == .array([.object(["id": .string("local"), "template": .string("clock"), "format": .string("EEE d MMM  h:mm a")])]))
    #expect(document["widgetOverrides"] == .object(["imported": .object(["style": .object(["fontSize": .number(15)]), "format": .string("EEE d MMM  h:mm a")])]))
}

@Test func setupWritesRootSettingsThatActiveProfilesCanStillOverride() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "setup-profile.json")
    let data = Data(##"""
    {
      "bar": {"height": 40, "offset": 5},
      "defaults": {"fontSize": 16, "foreground": "#abcdef"},
      "widgets": [{"id": "clock", "type": "clock", "position": "right"}],
      "profiles": [{"name": "desktop", "configuration": {
        "defaults": {"foreground": "#112233"},
        "bar": {"offset": 90},
        "widgetOverrides": {"clock": {"format": "ss"}}
      }}]
    }
    """##.utf8)
    let updated = try SetupPreferences(appearance: .dark, placement: .belowMenuBar, clock: .twelveHour)
        .applying(to: data, menuBarHeight: 24, configurationURL: root)
    let document = try JSONDecoder().decode([String: ConfigurationValue].self, from: updated)
    let original = try JSONDecoder().decode([String: ConfigurationValue].self, from: data)
    #expect(document["bar"] == .object(["height": .number(40), "offset": .number(24), "appearance": .string("dark")]))
    #expect(document["defaults"] == original["defaults"])
    #expect(document["widgets"] == .array([.object(["id": .string("clock"), "type": .string("clock"), "position": .string("right"),
                                                    "format": .string("EEE d MMM  h:mm a")])]))
    #expect(document["profiles"] == original["profiles"])
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root, data: updated)
    #expect(configuration.defaults.foreground == HexColor(0x112233ff))
    #expect(configuration.bar.offset == 90)
    #expect(configuration.widgets[0].content == .clock(format: "ss"))
}

@Test func setupFindsClocksIntroducedByTheCurrentProfile() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "setup-profile-clock.json")
    let data = Data(#"""
    {"widgets":[],"profiles":[
      {"name":"portable","when":{"onBattery":true},"configuration":{
        "widgets":[{"id":"portable-clock","type":"clock","position":"right","format":"ss"}]
      }}
    ]}
    """#.utf8)
    let context = ConfigurationContext(onBattery: true)
    let updated = try SetupPreferences(clock: .twelveHour)
        .applying(to: data, menuBarHeight: 24, configurationURL: root, context: context)
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root, data: updated, context: context)
    #expect(configuration.widgets[0].content == .clock(format: "EEE d MMM  h:mm a"))
}

@Test func layoutBlocksAreConcreteViews() {
    let body = String(reflecting: PopupBlockView.Body.self)
    let typeErased = body.contains("AnyView")
    let childrenAreBlockViews = body.contains("PopupBlockView")
    #expect(!typeErased)
    #expect(childrenAreBlockViews)
}
