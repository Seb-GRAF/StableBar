import AppKit
import SwiftUI
import Testing
@testable import StableBar

@Test(arguments: [900.0, 2000.0]) @MainActor
func previewWallpaperLeavesTheSettingsHeaderClickable(width: Double) throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let store = try fixture.store()
    defer { store.stop() }
    let editor = ConfigurationEditor(store: store)
    var tabClicks = 0
    let image = NSImage(size: NSSize(width: 1536, height: 1024), flipped: false) { rect in
        NSColor.gray.setFill()
        rect.fill()
        return true
    }
    let content = VStack(spacing: 0) {
        Button("Theme") { tabClicks += 1 }
            .buttonStyle(.plain)
            .frame(height: 52)
        ScreenBand(editor: editor, kinds: [.laptop, .monitor], screen: .laptop, useSharedBar: { _ in })
            .frame(height: 100)
        Wallpaper(backgroundImage: image)
            .frame(height: 82)
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
    .frame(width: width, height: 234)
    _ = NSApplication.shared
    // SwiftUI needs an ordered window for hit testing. Keep it invisible, and never start a bar.
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 234), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.contentView = NSHostingView(rootView: content)
    window.orderFrontRegardless()
    defer { window.close() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))

    func click(x: Double, y: Double) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 234 - y),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
    try click(x: width / 2, y: 26)
    #expect(tabClicks == 1)
    try click(x: 140, y: 95)
    let selectedScreen = editor.barScreen
    #expect(selectedScreen == .monitor)
    try click(x: width - 65, y: 102)
    let editingBar = store.barEditing.isActive
    #expect(editingBar)
}
