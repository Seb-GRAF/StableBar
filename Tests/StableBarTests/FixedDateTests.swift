import AppKit
import SwiftUI
import Testing
@testable import StableBar

/// Thursday 22 October 2026, 09:41 UTC: the time the docs images and scenes draw.
private let fixed = Date(timeIntervalSince1970: 1_792_662_060)
private let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)

/// The largest difference of one color channel between two drawings. A process draws some antialiased
/// pixels one step (1/255) differently between two drawings of the same content (see DefaultLayoutTests),
/// so drawings that match differ by at most 1.
private func difference(_ first: [UInt8], _ second: [UInt8]) -> Int {
    guard first.count == second.count else { return 255 }
    return zip(first, second).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
}

/// `content` drawn at 2× as 8-bit sRGB bytes.
@MainActor private func pixels(_ content: some View) throws -> [UInt8] {
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                         bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data)
    return Array(UnsafeRawBufferPointer(start: data, count: image.width * image.height * 4))
}

@Test @MainActor func barClockDrawsTheFixedDate() throws {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
    defer { fixture.close() }
    let store = try fixture.store()
    func bar(_ date: Date) throws -> [UInt8] {
        try pixels(BarView(store: store, display: display).frame(width: 600, height: 40).environment(\.fixedDate, date))
    }
    let first = try bar(fixed)
    #expect(try difference(bar(fixed.addingTimeInterval(3_600)), first) > 1)
    #expect(try difference(bar(fixed), first) <= 1)
}

@Test @MainActor func clockCalendarDrawsTheFixedDate() throws {
    func calendar(_ date: Date) throws -> [UInt8] {
        try pixels(ClockCalendar(timeZone: "UTC", appearance: WidgetAppearance(WidgetStyle(), defaults: WidgetStyle()), openCalendar: {})
            .frame(width: 320)
            .environment(\.fixedDate, date))
    }
    let first = try calendar(fixed)
    #expect(try difference(calendar(fixed.addingTimeInterval(40 * 86_400)), first) > 1)
    #expect(try difference(calendar(fixed), first) <= 1)
}

@Test func clockFormatSamplesUseTheGivenDate() {
    let format = WidgetClockFormat.common[4]
    #expect(format.value == "EEE d MMM  HH:mm")
    #expect(format.sample(at: fixed) != format.sample(at: fixed.addingTimeInterval(86_400)))
}

/// `content` drawn in an offscreen window, where a scroll view lays out its lazy grids, as the bitmap's bytes.
@MainActor private func windowPixels(_ content: some View, size: NSSize) throws -> [UInt8] {
    let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -9000, y: -6000), size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = NSHostingView(rootView: content)
    view.frame = CGRect(origin: .zero, size: size)
    window.contentView = view
    window.orderFrontRegardless()
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let data = try #require(bitmap.bitmapData)
    return Array(UnsafeBufferPointer(start: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
}

@Test @MainActor func clockSettingsSamplesDrawTheFixedDate() throws {
    // The clock shows only the time, so its own row draws the same a day later: only the format samples, which show
    // dates, can tell the two days apart, and they do only if they draw the date the render gives them.
    let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right","format":"HH:mm"}]}"#)
    defer { fixture.close() }
    let editor = ConfigurationEditor(store: try fixture.store())
    editor.selectedID = "clock"
    func settings(_ date: Date) throws -> [UInt8] {
        try windowPixels(BarInspector(editor: editor, screen: .laptop, kinds: [.laptop], names: [:], source: { _ in .builtIn },
                                      useSharedBar: { _ in }, remove: { _ in }, scrollPositions: .constant([:]))
            .environment(\.fixedDate, date), size: NSSize(width: 560, height: 1000))
    }
    let first = try settings(fixed)
    #expect(try difference(settings(fixed.addingTimeInterval(86_400)), first) > 1)
    #expect(try difference(settings(fixed), first) <= 1)
}

@Test @MainActor func shimmerDrawsTheFixedDate() async throws {
    func shimmer() throws -> [UInt8] {
        try pixels(Text("Loading the answer").font(.system(size: 20)).modifier(Shimmer(active: true))
            .frame(width: 240, height: 40).background(Color.black).environment(\.fixedDate, fixed))
    }
    let first = try shimmer()
    try await Task.sleep(for: .milliseconds(600))
    #expect(try difference(shimmer(), first) <= 1)
}
