import AppKit
@testable import StableBar
import SwiftUI
import Testing

/// A step that advances each time the drawing checks whether its views are ready, up to the last one.
@MainActor @Observable private final class Steps {
    var step = 0
}

/// Red until the last step, then blue.
private struct StepColor: View {
    let steps: Steps

    var body: some View {
        steps.step < 3 ? Color(red: 1, green: 0, blue: 0) : Color(red: 0, green: 0, blue: 1)
    }
}

@Test @MainActor func aStillDrawingKeepsDrawingUntilItsViewsStopChanging() async throws {
    let steps = Steps()
    let png = try await OffscreenSnapshot.png(StepColor(steps: steps), size: NSSize(width: 20, height: 20),
                                              pixels: NSSize(width: 20, height: 20), dark: false, settle: .still, ready: {
        steps.step = min(steps.step + 1, 3)
        return true
    }, name: "steps")
    let color = try #require(NSBitmapImageRep(data: png)?.colorAt(x: 10, y: 10))
    #expect(color.blueComponent > 0.9)
    #expect(color.redComponent < 0.1)
}

/// The loading hold finds SwiftUI's spinning `ProgressView` as AppKit's indicator in the drawn views.
@Test @MainActor func aSpinningProgressViewShowsAsLoading() {
    let views: [(AnyView, Bool)] = [(AnyView(ProgressView()), true), (AnyView(ProgressView("Loading…")), true),
                                    (AnyView(ProgressView(value: 0.5)), false), (AnyView(Text("Loaded")), false)]
    for (content, loading) in views {
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
        let window = NSWindow(contentRect: NSRect(x: -9000, y: -6000, width: 200, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Issue.record("No image to draw in")
            return
        }
        view.cacheDisplay(in: view.bounds, to: image)
        #expect(OffscreenSnapshot.showsLoading(view) == loading, "\(content)")
        window.close()
    }
}
