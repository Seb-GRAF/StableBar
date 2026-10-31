import AppKit
import SwiftUI
import Testing
@testable import StableBar

/// Records requests to `offline-image.invalid` and fails them, so a test can tell which images asked the network.
private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "offline-image.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let url = request.url { Self.requests.append(url) }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

@Test @MainActor func sampleAppComesFromItsBundle() {
    let app = SampleApp(bundleIdentifier: "com.apple.calculator")
    #expect(app.localizedName == "Calculator")
    #expect(app.icon != nil)
    #expect(app.bundleIdentifier == "com.apple.calculator")
}

@Test @MainActor func offlineImagesMakeNoRequest() async throws {
    URLProtocol.registerClass(RecordingURLProtocol.self)
    defer { URLProtocol.unregisterClass(RecordingURLProtocol.self) }
    RecordingURLProtocol.requests = []
    func show(_ path: String, offline: Bool) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -9000, y: -6000, width: 120, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WidgetImage(path: path, fit: .fit).frame(width: 100, height: 100)
            .environment(\.offline, offline))
        window.orderFrontRegardless()
        return window
    }
    let windows = [show("https://offline-image.invalid/offline.png", offline: true),
                   show("https://offline-image.invalid/online.png", offline: false)]
    defer { windows.forEach { $0.close() } }
    // The online image is the control: once its request arrives, both images have loaded. Wait for it by
    // polling, since a busy main actor can delay the images' tasks well past any fixed sleep.
    for _ in 0..<150 where RecordingURLProtocol.requests.isEmpty {
        try await Task.sleep(for: .milliseconds(100))
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(RecordingURLProtocol.requests.map(\.lastPathComponent) == ["online.png"])
}
