import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import os
@testable import StableBar

private var presentationRepository: URL {
    URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

@MainActor private func waitForPopup(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Test(arguments: [false, true]) @MainActor func hoverTooltipsFitTheirTextAndDoNotCaptureClicks(long: Bool) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(##"""
    {"defaults":{"foreground":"#f4f4f5","background":"#25252c","borderWidth":0,"cornerRadius":9,"fontSize":12},
     "widgets":[{"id":"session","type":"text","text":"Amphetamine","position":"right",
      "popup":{"style":{},"layout":{"type":"text","text":"Session details"}}}]}
    """##.utf8))
    var presentations: [(panel: PopupPanel, onHover: Bool)] = []
    let popup = WidgetPopup(present: { presentations.append(($0, $1)) })
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    _ = try bar.bitmap(name: "hover-tooltip-before-\(long)")
    let widget = configuration.widgets[0]
    let anchor = try #require(bar.anchors(widget.id).first)
    let text = long ? Array(repeating: "Will not sleep for 1 hour", count: 10).joined(separator: "\n") : "Will not sleep for 1 hour"
    func hover(_ inside: Bool) {
        popup.hover(inside, store: store, anchor: anchor) {
            popup.showTooltip(text, widget: widget, defaults: configuration.popupDefaults.inheriting(configuration.defaults),
                              store: store, anchor: anchor)
        }
    }
    hover(true)
    #expect(presentations.isEmpty)
    try await waitForPopup { !presentations.isEmpty }
    let tooltip = try #require(presentations.first)
    try capturePopup(tooltip.panel, name: "hover-tooltip-after-\(long)")
    #expect(tooltip.onHover)
    #expect(tooltip.panel.ignoresMouseEvents)
    #expect(tooltip.panel.frame.width <= 320)
    #expect(tooltip.panel.frame.height > (long ? 100 : 20))
    #expect(bar.panel.screen!.visibleFrame.contains(tooltip.panel.frame))
    #expect(store.presentations[widget.id]?.popupAnchor == nil)
    popup.toggle(widget.popup!, widget: widget, defaults: configuration.defaults, store: store, anchor: anchor)
    #expect(presentations.count == 2)
    #expect(presentations.last?.onHover == false)
    try capturePopup(try #require(presentations.last?.panel), name: "hover-tooltip-click-popup-\(long)")
    #expect(store.presentations[widget.id]?.popupAnchor == ObjectIdentifier(anchor))
    hover(false)
    try await Task.sleep(for: .milliseconds(250))
    #expect(popup.isOpen)
    popup.close()
    hover(true)
    try await waitForPopup { popup.isOpen }
    hover(false)
    try await waitForPopup { !popup.isOpen }
    #expect(!popup.isOpen)
    #expect(presentations.allSatisfy { !$0.panel.isVisible })
}

@Test @MainActor func popupCommandTogglesTheWidgetsPopupOnTheActiveDisplay() async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"agenda-command","type":"text","text":"Agenda","position":"right",
      "popup":{"style":{},"layout":{"type":"text","text":"Today"}}}]}
    """#.utf8))
    let popup = WidgetPopup(present: { _, _ in })
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    store.barPanel = { _ in bar.panel }
    let anchor = try #require(bar.anchors("agenda-command").first)
    _ = try store.handle(RuntimeRequest(action: .popup, id: "agenda-command"))
    #expect(store.presentations["agenda-command"]?.popupAnchor == ObjectIdentifier(anchor))
    _ = try store.handle(RuntimeRequest(action: .popup, id: "agenda-command"))
    #expect(!popup.isOpen)
    #expect(throws: CommandFailure.self) { try store.handle(RuntimeRequest(action: .popup, id: "missing")) }
}

@Test @MainActor func hoveringPopupsWaitsAndKeepsBothTheWidgetAndPopupReachable() async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"popups":{"details":{"openOnHover":true,"style":{},"layout":{"type":"text","text":"Details"}}},
     "widgets":[{"id":"first","type":"text","text":"First","position":"right","popupName":"details"},
                {"id":"second","type":"text","text":"Second","position":"right","popupName":"details"}]}
    """#.utf8))
    var presentations: [(panel: PopupPanel, onHover: Bool)] = []
    let popup = WidgetPopup(present: { presentations.append(($0, $1)) })
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let anchors = try configuration.widgets.map { try #require(bar.anchors($0.id).first) }
    let details = try #require(configuration.popups["details"])
    func hover(_ inside: Bool, _ index: Int = 0) {
        popup.hover(inside, store: store, anchor: anchors[index]) {
            popup.open(details, widget: configuration.widgets[index], defaults: configuration.defaults,
                       store: store, anchor: anchors[index], onHover: true)
        }
    }
    func click(_ index: Int = 0) {
        popup.toggle(details, widget: configuration.widgets[index], defaults: configuration.defaults, store: store, anchor: anchors[index])
    }

    hover(true)
    try await Task.sleep(for: .milliseconds(100))
    #expect(!popup.isOpen)
    hover(false)
    try await Task.sleep(for: .milliseconds(450))
    #expect(presentations.isEmpty)

    hover(true)
    try await waitForPopup { popup.isOpen }
    #expect(popup.isOpen)
    #expect(presentations.count == 1)
    #expect(presentations.first?.onHover == true)
    #expect(store.presentations["first"]?.popupAnchor == ObjectIdentifier(anchors[0]))
    hover(false)
    #expect(popup.isOpen)
    popup.hoverPopup(true)
    try await Task.sleep(for: .milliseconds(250))
    #expect(popup.isOpen)
    popup.hoverPopup(false)
    hover(true)
    try await Task.sleep(for: .milliseconds(250))
    #expect(popup.isOpen)
    #expect(presentations.count == 1)
    hover(false)
    try await waitForPopup { !popup.isOpen }
    #expect(!popup.isOpen)
    #expect(store.presentations["first"]?.popupAnchor == nil)

    hover(true)
    try await waitForPopup { popup.isOpen }
    hover(false)
    hover(true, 1)
    popup.hoverPopup(false)
    try await waitForPopup { store.presentations["second"]?.popupAnchor != nil }
    #expect(popup.isOpen)
    #expect(store.presentations["first"]?.popupAnchor == nil)
    #expect(store.presentations["second"]?.popupAnchor == ObjectIdentifier(anchors[1]))
    click(1)
    let count = presentations.count
    hover(false, 1)
    hover(true)
    try await Task.sleep(for: .milliseconds(500))
    #expect(presentations.count == count)
    #expect(store.presentations["second"]?.popupAnchor == ObjectIdentifier(anchors[1]))
    click(1)
    #expect(!popup.isOpen)

    hover(true)
    click()
    #expect(presentations.last?.onHover == false)
    hover(false)
    try await Task.sleep(for: .milliseconds(500))
    #expect(popup.isOpen)
    #expect(presentations.count == count + 1)
    click()
    #expect(!popup.isOpen)
    #expect(presentations.allSatisfy { !$0.panel.isVisible })
}

/// Only the open state sets a background, so opening the popup makes glass start drawing behind the widget,
/// as leaving a widget whose hover background disappears does.
@Test(arguments: [false, true]) @MainActor func clickedPopupStaysOpenWhenItsWidgetBackgroundChanges(glass: Bool) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"bar":{"glass":{"enabled":\#(glass)}},
     "popups":{"details":{"style":{},"layout":{"type":"text","text":"Details"}}},
     "widgets":[{"id":"first","type":"text","text":"First","position":"right","popupName":"details",
                 "style":{"states":{"open":{"background":"#ff0000"}}}}]}
    """#.utf8))
    let popup = WidgetPopup(present: { _, _ in })
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let anchor = try #require(bar.anchors("first").first)
    let details = try #require(configuration.popups["details"])

    popup.toggle(details, widget: configuration.widgets[0], defaults: configuration.defaults, store: store, anchor: anchor)
    await bar.settle()
    try await Task.sleep(for: .milliseconds(100))
    #expect(popup.isOpen)
    #expect(store.presentations["first"]?.popupAnchor == ObjectIdentifier(anchor))
}

@Test(arguments: [false, true]) @MainActor func pendingHoverIsCancelledWhenDismissedOrRemoved(remove: Bool) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"agenda","type":"text","text":"Agenda","position":"right",
      "popup":{"openOnHover":true,"style":{},"layout":{"type":"text","text":"Today"}}}]}
    """#.utf8))
    var presentations = 0
    let popup = WidgetPopup(present: { _, _ in presentations += 1 })
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let widget = configuration.widgets[0]
    let anchor = try #require(bar.anchors(widget.id).first)
    popup.hover(true, store: store, anchor: anchor) {
        popup.open(widget.popup!, widget: widget, defaults: configuration.defaults, store: store, anchor: anchor, onHover: true)
    }
    if remove { popup.removeAnchor(anchor) } else { popup.close() }
    try await Task.sleep(for: .milliseconds(500))
    #expect(presentations == 0)
    #expect(!popup.isOpen)
    #expect(store.presentations[widget.id]?.popupAnchor == nil)
}

@Test(arguments: [false, true], [false, true]) @MainActor
func popupResizesWithItsContentAndKeepsItsWidthAndTopEdge(fixedHeight: Bool, animated: Bool) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data("""
    {"widgets":[{"id":"update","type":"text","text":"Update","position":"right","popup":{
        \(fixedHeight ? "\"height\":140," : "")
        \(animated ? "\"animation\":{\"duration\":0.05}," : "")
        "style":{"width":300,"paddingHorizontal":14,"paddingVertical":14},
        "layout":{"type":"text","text":"An update is available"}}}]}
    """.utf8))
    var presented: PopupPanel?
    let popup = WidgetPopup(present: { panel, _ in presented = panel })
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let widget = configuration.widgets[0]
    popup.toggle(widget.popup!, widget: widget, defaults: configuration.defaults, store: store,
                 anchor: try #require(bar.anchors(widget.id).first))
    let panel = try #require(presented)
    defer { popup.close() }
    let opened = panel.frame
    for _ in 0..<8 {
        panel.contentView!.layoutSubtreeIfNeeded()
        let host = panel.contentView!.subviews[0]
        host.cacheDisplay(in: host.bounds, to: try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)))
        try await Task.sleep(for: .milliseconds(25))
    }
    let initial = panel.frame
    #expect(initial == opened)
    for lines in [5, 100, 0] {
        store.actionErrors[widget.id] = lines == 0 ? nil : Array(repeating: "Download progress", count: lines).joined(separator: "\n")
        for _ in 0..<8 {
            panel.contentView!.layoutSubtreeIfNeeded()
            let host = panel.contentView!.subviews[0]
            host.cacheDisplay(in: host.bounds, to: try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)))
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(panel.frame.width == initial.width)
        #expect(abs(panel.frame.maxY - initial.maxY) < 0.5)
        #expect(panel.frame.minY >= bar.panel.screen!.visibleFrame.minY + 8)
        #expect(panel.contentView!.subviews[0].frame == panel.contentView!.bounds)
        if fixedHeight || lines == 0 {
            #expect(abs(panel.frame.height - initial.height) < 0.5)
        } else {
            #expect(panel.frame.height > initial.height)
        }
        #expect(!panel.isVisible)
    }
}

/// macOS outlines a window and shapes its shadow from what the window draws, so a popup's own shadow, drawn in the
/// popup's window, got an outline near its outer edge (#180). That shadow is drawn in a window behind the popup instead.
@Test(arguments: [nil, "#00000000", "#00000059"] as [String?]) @MainActor
func popupDrawsItsOwnShadowInAWindowBehindIt(shadowColor: String?) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data("""
    {"widgets":[{"id":"work","type":"text","text":"Work","position":"right","popup":{
        "style":{"width":300,"cornerRadius":14,"background":"#202020","shadowRadius":14,
                 "shadowColor":\(shadowColor.map { "\"\($0)\"" } ?? "null")},
        "layout":{"type":"text","text":"Reviews"}}}]}
    """.utf8))
    var presented: PopupPanel?
    let popup = WidgetPopup(present: { panel, _ in presented = panel })
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let widget = configuration.widgets[0]
    popup.toggle(widget.popup!, widget: widget, defaults: configuration.defaults, store: store,
                 anchor: try #require(bar.anchors(widget.id).first))
    let panel = try #require(presented)
    func settle() async throws {
        for _ in 0..<8 {
            _ = try alpha(of: panel.contentView!, at: NSPoint(x: 1, y: 1))
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    try await settle()
    #expect(panel.hasShadow)
    // The panel leaves 14 × 2 + 2 points around the popup. This point is 4 points left of it.
    let beside = NSPoint(x: 26, y: panel.frame.height / 2)
    #expect(try alpha(of: panel.contentView!, at: beside) == 0)
    guard shadowColor == "#00000059" else {
        #expect(popup.shadowWindow == nil)
        popup.close()
        return
    }
    let shadow = try #require(popup.shadowWindow)
    #expect(!shadow.hasShadow)
    #expect(shadow.ignoresMouseEvents)
    #expect(!shadow.isVisible)
    #expect(shadow.frame == panel.frame)
    #expect(try alpha(of: shadow.contentView!, at: beside) > 0)
    #expect(try alpha(of: shadow.contentView!, at: NSPoint(x: panel.frame.width / 2, y: beside.y)) == 0)
    let opened = panel.frame
    store.actionErrors[widget.id] = Array(repeating: "Pipeline failed", count: 5).joined(separator: "\n")
    try await settle()
    #expect(panel.frame.height > opened.height)
    #expect(shadow.frame == panel.frame)
    popup.close()
    #expect(popup.shadowWindow == nil)
}

@MainActor private func alpha(of view: NSView, at point: NSPoint) throws -> CGFloat {
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
    // Bitmap rows run from the top.
    return try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int((view.bounds.height - point.y) * scale))).alphaComponent
}

@MainActor private final class PresentationFixtureSource: DataSource {
    let output: ScriptOutput
    var starts = 0
    var stops = 0
    private var emit: (@Sendable (SourceUpdate) -> Void)?
    init(output: ScriptOutput) { self.output = output }
    func start(emit: @escaping @Sendable (SourceUpdate) -> Void) { starts += 1; self.emit = emit }
    func refresh(event: ScriptEvent) { emit?(.output(.success(output))) }
    func stop() { stops += 1; emit = nil }
}

@MainActor private func capturePopup(_ panel: PopupPanel, name: String) throws {
    guard let output = ProcessInfo.processInfo.environment["STABLEBAR_RENDER_OUTPUT"], let view = panel.contentView else { return }
    view.layoutSubtreeIfNeeded()
    let size = view.bounds.size
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * 2).rounded()),
        pixelsHigh: Int((size.height * 2).rounded()), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(filePath: output).appending(path: name + ".png"))
}

@Test @MainActor func deliveredTonhalleExampleRendersTwoDisplaysAndKeepsSourcesAndPopupLifecycle() async throws {
    let repository = presentationRepository
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.copyItem(at: repository.appending(path: "examples/presentation"), to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let packages = WidgetPackageStore(directory: directory.appending(path: "packages"))
    let inspection = try packages.install(repository.appending(path: "examples/packages/tonhalle-line"))
    #expect(inspection.manifest.version == "1.1.0")
    #expect(inspection.commands.isEmpty)
    let source = PresentationFixtureSource(output: try ScriptOutput.read(Data(contentsOf: directory.appending(path: "sample.json"))))
    var command = DataSourceType.command
    command.continuous = true
    command.makeSource = { _, _ in source }
    let registry = DataSourceRegistry(types: [command])
    var popupPanel: PopupPanel?
    let popup = WidgetPopup(present: { panel, _ in popupPanel = panel }) // actual native popup, never ordered
    let store = BarStore(configurationURL: directory.appending(path: "config.json"), registry: registry, popup: popup,
                         themesDirectory: repository.appending(path: "Resources/themes"))
    let executable = directory.appending(path: "aerospace-fixture")
    let script = #"""
    #!/bin/sh
    case "$1" in
      subscribe) printf '%s\n' '{"_event":"mode-changed","mode":"main"}'; exec /bin/sleep 60 ;;
      list-workspaces) printf '%s\n' '[{"workspace":"1","workspace-is-focused":true,"workspace-is-visible":true,"monitor-appkit-nsscreen-screens-id":1},{"workspace":"2","workspace-is-focused":false,"workspace-is-visible":false,"monitor-appkit-nsscreen-screens-id":1},{"workspace":"3","workspace-is-focused":false,"workspace-is-visible":true,"monitor-appkit-nsscreen-screens-id":2}]' ;;
      list-windows) printf '%s\n' '[{"workspace":"1","app-name":"Finder","app-bundle-id":"com.apple.finder","window-id":1,"window-title":"Window 1"},{"workspace":"1","app-name":"Terminal","app-bundle-id":"com.apple.Terminal","window-id":2,"window-title":"Window 2"},{"workspace":"3","app-name":"Finder","app-bundle-id":"com.apple.finder","window-id":3,"window-title":"Window 3"}]' ;;
    esac
    """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    store.workspaceStore.executablePath = { executable.path }
    store.activeApp = nil
    store.reloadConfiguration()
    defer { store.stop() }
    for _ in 0..<100 {
        if store.scripts["music"]?.output.fields?["track"] != nil && store.workspaceStore.mode == "main" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.configurationError == nil)
    let configuration = try #require(store.configuration)
    #expect(configuration.widgets.count >= 15)
    let shared = try #require(store.providers["sample"])
    #expect(store.scripts["music"] === shared && store.scripts["cpu"] === shared && store.scripts["memory"] === shared)
    let laptop = OffscreenBar(configuration: configuration, display: BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: 661...851),
                             width: 1512, sharedStore: store)
    let external = OffscreenBar(configuration: configuration, display: BarDisplay(id: 2, isBuiltIn: false, isMain: false, notch: nil),
                               width: 2560, sharedStore: store)
    defer { laptop.close(); external.close() }
    store.onConfigurationChange = { laptop.refreshGeometry(); external.refreshGeometry() }
    await laptop.settle()
    await external.settle()
    #expect(laptop.anchors("hidden-example").isEmpty && external.anchors("hidden-example").isEmpty)
    #expect(laptop.anchors("mode").isEmpty)
    #expect(laptop.anchors("time").count == 1 && external.anchors("time").count == 1)
    #expect(store.presentations["time"]?.style.base.fontSize == 16)
    #expect(store.presentations["time"]?.style.base.fontWeight == "light")
    #expect(store.presentations["date"]?.style.base.fontSize == 12)
    let frames = [laptop.panel.frame, external.panel.frame, laptop.panel.drawingFrame, external.panel.drawingFrame]
    _ = try laptop.bitmap(name: "tonhalle-dark-1512-main")
    _ = try external.bitmap(name: "tonhalle-dark-2560-main")

    for (id, popupName) in [("music", "music"), ("cpu", "system"), ("meeting", "agenda"), ("time", "clock")] {
        let widget = try #require(configuration.widgets.first { $0.id == id })
        let anchor = try #require(external.anchors(id).first)
        popup.toggle(try #require(configuration.popups[popupName]), widget: widget,
            defaults: configuration.popupDefaults.inheriting(configuration.defaults), store: store, anchor: anchor)
        await external.settle()
        let panel = try #require(popupPanel)
        #expect(!panel.isVisible && popup.isOpen)
        #expect(store.presentations[id]?.popupAnchor == ObjectIdentifier(anchor))
        #expect(laptop.anchors(id).first.map(ObjectIdentifier.init) != store.presentations[id]?.popupAnchor)
        try capturePopup(panel, name: "tonhalle-dark-\(popupName)-popup")
        store.workspaceStore.acceptMode("tailing")
        #expect(popup.isOpen)
        #expect(store.barStyle.borderEdges == .all)
        #expect(store.barStyle.borderColor == HexColor(light: 0x806323ff, dark: 0xc8a866ff))
        popup.close()
        store.workspaceStore.acceptMode("main")
    }
    store.workspaceStore.acceptMode("tailing")
    for _ in 0..<100 {
        if store.presentations["mode"]?.hidden == false { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    await laptop.settle()
    _ = try laptop.bitmap(name: "tonhalle-dark-1512-command")
    _ = try external.bitmap(name: "tonhalle-dark-2560-command")
    #expect(laptop.anchors("mode").count == 1)
    #expect([laptop.panel.frame, external.panel.frame, laptop.panel.drawingFrame, external.panel.drawingFrame] == frames)
    #expect(source.starts == 1)
    let time = try #require(configuration.widgets.first { $0.id == "time" })
    popup.toggle(try #require(time.popupName.flatMap { configuration.popups[$0] }), widget: time,
        defaults: configuration.popupDefaults.inheriting(configuration.defaults), store: store, anchor: try #require(external.anchors("time").first))
    #expect(popup.isOpen)
    try store.applyEdits([ConfigurationEdit(action: .bar, properties: ["appearance": .string("light")])], persist: false)
    #expect(!popup.isOpen)
    #expect(store.workspaceStore.mode == "tailing")
    #expect(store.providers["sample"] === shared && source.starts == 1)
    await laptop.settle()
    _ = try laptop.bitmap(name: "tonhalle-light-1512-command")
    _ = try external.bitmap(name: "tonhalle-light-2560-command")
    let light = try #require(store.configuration)
    for (id, popupName) in [("music", "music"), ("cpu", "system"), ("meeting", "agenda"), ("time", "clock")] {
        let widget = try #require(light.widgets.first { $0.id == id })
        popup.toggle(try #require(light.popups[popupName]), widget: widget,
            defaults: light.popupDefaults.inheriting(light.defaults), store: store, anchor: try #require(external.anchors(id).first))
        await external.settle()
        try capturePopup(try #require(popupPanel), name: "tonhalle-light-\(popupName)-popup")
        popup.close()
    }
    store.workspaceStore.acceptMode("main")
    await laptop.settle()
    _ = try laptop.bitmap(name: "tonhalle-light-1512-main")
    _ = try external.bitmap(name: "tonhalle-light-2560-main")
    store.workspaceStore.acceptMode("tailing")
    let music = try #require(light.widgets.first { $0.id == "music" })
    popup.toggle(try #require(light.popups["music"]), widget: music, defaults: light.popupDefaults.inheriting(light.defaults),
                 store: store, anchor: try #require(external.anchors("music").first))
    #expect(popup.isOpen)
    try store.applyEdits([ConfigurationEdit(action: .theme)], persist: false)
    #expect(!popup.isOpen)
    #expect(store.workspaceStore.mode == "tailing")
    #expect(store.barStyle.borderEdges != .all)
    #expect(store.presentations["time"]?.style.base.fontSize == store.configuration?.defaults.fontSize)
    #expect(store.providers["sample"] === shared && source.starts == 1)
    await laptop.settle()
    _ = try laptop.bitmap(name: "built-in-light-1512-command")
    _ = try external.bitmap(name: "built-in-light-2560-command")
    #expect(laptop.panel.decorationPanel == nil && external.panel.decorationPanel == nil)
    let builtIn = try #require(store.configuration)
    for (id, popupName) in [("music", "music"), ("cpu", "system"), ("meeting", "agenda"), ("time", "clock")] {
        let widget = try #require(builtIn.widgets.first { $0.id == id })
        popup.toggle(try #require(builtIn.popups[popupName]), widget: widget,
            defaults: builtIn.popupDefaults.inheriting(builtIn.defaults), store: store, anchor: try #require(external.anchors(id).first))
        await external.settle()
        try capturePopup(try #require(popupPanel), name: "built-in-light-\(popupName)-popup")
        popup.close()
    }
}

@Test @MainActor func presentationPerformanceSeparatesStyleResolutionInvalidationAndNativeGeometry() async throws {
    let repository = presentationRepository
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.copyItem(at: repository.appending(path: "examples/presentation"), to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try WidgetPackageStore(directory: directory.appending(path: "packages"))
        .install(repository.appending(path: "examples/packages/tonhalle-line"))
    var loader = ConfigurationLoader()
    loader.themesDirectory = repository.appending(path: "Resources/themes")
    let config = try loader.load(directory.appending(path: "config.json"))
    let store = BarStore(configurationURL: directory.appending(path: "config.json"))
    store.configuration = config
    store.activeApp = nil
    store.workspaceStore.workspaces = [Workspace(name: "1", isFocused: true, isVisible: true, monitor: 1),
                                        Workspace(name: "2", isFocused: false, isVisible: true, monitor: 2)]
    let shared = ScriptWidget()
    try shared.accept(ScriptOutput.read(Data(contentsOf: directory.appending(path: "sample.json"))))
    let mode = ScriptWidget()
    try mode.accept(ScriptOutput.read(Data(#"{"text":"","hidden":true}"#.utf8)))
    for widget in config.widgets where widget.providerName == "sample" { store.scripts[widget.id] = shared }
    store.scripts["mode"] = mode
    store.preparePresentations()
    defer { store.stop() }
    let laptopDisplay = BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: 661...851)
    let externalDisplay = BarDisplay(id: 2, isBuiltIn: false, isMain: false, notch: nil)
    let laptop = OffscreenBar(configuration: config, display: laptopDisplay, width: 1512, sharedStore: store)
    let external = OffscreenBar(configuration: config, display: externalDisplay, width: 2560, sharedStore: store)
    defer { laptop.close(); external.close() }
    await laptop.settle()
    await external.settle()
    let anchorsBefore = external.anchors("time").map { $0.convert($0.bounds, to: external.host) }
    let framesBefore = [laptop.panel.drawingFrame, external.panel.drawingFrame]
    let hostingBefore = laptop.host.layoutCalls + external.host.layoutCalls
    let start = ContinuousClock.now
    for _ in 0..<100 { store.updatePresentations() }
    let elapsed = start.duration(to: .now).components
    let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    let changes = OSAllocatedUnfairLock(initialState: (layout: 0, widget: 0, bar: 0))
    let bar = BarView(store: store, display: laptopDisplay, nativeDecorations: true)
    for index in 0..<100 {
        withObservationTracking { _ = bar.body } onChange: { changes.withLock { $0.layout += 1 } }
        withObservationTracking { for presentation in store.presentations.values { _ = presentation.style } }
            onChange: { changes.withLock { $0.widget += 1 } }
        withObservationTracking { _ = store.barStyle } onChange: { changes.withLock { $0.bar += 1 } }
        store.workspaceStore.acceptMode(index.isMultiple(of: 2) ? "tailing" : "main")
    }
    let invalidations = changes.withLock { $0 }
    #expect(invalidations.layout == 0)
    #expect(invalidations.widget == 0)
    #expect(invalidations.bar == 100)
    await laptop.settle()
    await external.settle()
    #expect(external.anchors("time").map { $0.convert($0.bounds, to: external.host) } == anchorsBefore)
    #expect([laptop.panel.drawingFrame, external.panel.drawingFrame] == framesBefore)
    let hostingLayouts = laptop.host.layoutCalls + external.host.layoutCalls - hostingBefore
    let visibility = OSAllocatedUnfairLock(initialState: 0)
    withObservationTracking { _ = bar.body } onChange: { visibility.withLock { $0 += 1 } }
    try mode.accept(ScriptOutput.read(Data(#"{"text":"Mode","hidden":false}"#.utf8)))
    #expect(visibility.withLock { $0 } == 1)
    if let output = ProcessInfo.processInfo.environment["STABLEBAR_RENDER_OUTPUT"] {
        let metrics: [String: ConfigurationValue] = [
            "widgets": .number(Double(config.widgets.count)), "displays": .array([.number(1512), .number(2560)]),
            "styleResolutionPasses": .number(100), "styleResolutionMilliseconds": .number(milliseconds),
            "modeUpdates": .number(100), "barDecorationInvalidations": .number(Double(invalidations.bar)),
            "barLayoutViewInvalidations": .number(Double(invalidations.layout)), "widgetStyleInvalidations": .number(Double(invalidations.widget)),
            "nativeHostingLayoutCalls": .number(Double(hostingLayouts)), "anchorAndPanelGeometryUnchanged": .bool(true),
            "modeWidgetVisibilityInvalidations": .number(1),
            "note": .string("Native hosting layout calls include SwiftUI/AppKit maintenance; they are not horizontal planner executions. No speedup claim is made.")]
        try configurationData(metrics).write(to: URL(filePath: output).appending(path: "performance.json"))
    }
}
