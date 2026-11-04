import AppKit
import SwiftUI
import Testing
@testable import StableBar

@Test(arguments: [900.0, 2000.0]) @MainActor
func previewWallpaperLeavesTheSettingsHeaderClickable(width: Double) async throws {
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
    let host = NSHostingView(rootView: content)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.close() }

    func poll(until condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            await Task.yield()
        }
        return false
    }
    let ready = await poll {
        window.isVisible && host.frame.size == NSSize(width: width, height: 234)
            && host.hitTest(CGPoint(x: width / 2, y: 26)) != nil
    }
    try #require(ready)

    func click(x: Double, y: Double, until condition: () -> Bool) async throws -> Bool {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 234 - y),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        return await poll(until: condition)
    }
    let clickedTab = try await click(x: width / 2, y: 26) { tabClicks == 1 }
    #expect(clickedTab)
    let selectedScreen = try await click(x: 140, y: 95) { editor.barScreen == .monitor }
    #expect(selectedScreen)
    let editingBar = try await click(x: width - 65, y: 102) { store.barEditing.isActive }
    #expect(editingBar)
}
