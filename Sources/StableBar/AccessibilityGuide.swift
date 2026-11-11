import AppKit
@preconcurrency import ApplicationServices
import SwiftUI

@MainActor let accessibilityGuide = AccessibilityGuide()

@MainActor
final class AccessibilityGuide: NSObject {
    private var panel: NSPanel?
    private var timer: Timer?

    func show() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces]
        let host = NSHostingView(rootView: AccessibilityGuideView { [weak self] in self?.close() })
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        self.panel = panel
        // Polled because System Settings' window can only be watched through Accessibility, which StableBar lacks here.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationTerminated),
                                                          name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    private func follow() {
        guard let panel else { return }
        guard let settings = NSWorkspace.shared.frontmostApplication, settings.bundleIdentifier == "com.apple.systempreferences",
              let window = largestWindow(of: settings.processIdentifier) else { return panel.orderOut(nil) }
        if AXIsProcessTrusted() { return close() }
        panel.setFrameOrigin(NSPoint(x: window.midX - panel.frame.width / 2, y: NSScreen.screens[0].frame.maxY - window.maxY + 16))
        panel.orderFrontRegardless()
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == "com.apple.systempreferences" { close() }
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        panel?.close()
        panel = nil
    }
}

/// The main window, in window server coordinates: the password prompt is a smaller window of System Settings.
private func largestWindow(of pid: pid_t) -> CGRect? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
    return windows.filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as! Int == 0 }
        .map { CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! CFDictionary)! }
        .max { $0.width * $0.height < $1.width * $1.height }
}

struct AccessibilityGuideView: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Drag StableBar into the list above", systemImage: "arrow.up").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close")
            }
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24)
                Text("StableBar")
                Spacer()
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(AppBundleDragSource())
            VStack(alignment: .leading, spacing: 2) {
                Text("Can't drag? Choose + below the list and open StableBar.")
                Text("Already in the list? Turn its switch on.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AppBundleDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> AppBundleDragView { AppBundleDragView() }
    func updateNSView(_ view: AppBundleDragView, context: Context) {}
}

private final class AppBundleDragView: NSView, NSDraggingSource {
    // The panel never becomes key, so every click on it is a first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), contents: NSApp.applicationIconImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
