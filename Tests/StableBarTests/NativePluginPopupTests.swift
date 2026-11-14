import AppKit
import Foundation
import Testing
@testable import StableBar

@MainActor
private final class FixedSizePopupView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 90) }
}

@Test @MainActor func widgetPopupHostsAndReleasesNativeViewThroughItsPanelLifecycle() async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"native","type":"text","text":"Native","position":"right",
      "popup":{"pinnable":true,"animation":{"duration":0},"style":{},"layout":{"type":"text","text":"unused"}}}]}
    """#.utf8))
    var panels: [PopupPanel] = []
    let popup = WidgetPopup(present: { panel, _ in panels.append(panel) })
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
    let content = FixedSizePopupView()
    let opened = popup.open(content, popup: try #require(widget.popup), widget: widget, defaults: configuration.defaults,
                            store: store, anchor: anchor, onHover: false)
    #expect(opened)
    #expect(!popup.open(content, popup: try #require(widget.popup), widget: widget, defaults: configuration.defaults,
                        store: store, anchor: anchor, onHover: false))

    let panel = try #require(panels.first)
    #expect(panel.title == "native popup")
    #expect(panel.frame.width >= 180)
    #expect(content.superview != nil)
    #expect(store.presentations[widget.id]?.popupAnchor == ObjectIdentifier(anchor))

    popup.close(widgetID: "other")
    #expect(popup.isOpen)
    popup.close(widgetID: widget.id)
    for _ in 0..<20 where content.superview != nil {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(!popup.isOpen)
    #expect(store.presentations[widget.id]?.popupAnchor == nil)
    #expect(content.superview == nil)
}
