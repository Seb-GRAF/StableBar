import AppKit
import SwiftUI

enum ThemeTrialPlacement {
    static func screenIndex(at point: CGPoint, frames: [CGRect], mainIndex: Int?, barIndices: [Int]) -> Int? {
        let available = barIndices.filter { frames.indices.contains($0) }
        return available.first {
            let frame = frames[$0]
            return point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
        } ?? available.first { $0 == mainIndex } ?? available.first
    }

    static func frame(size: CGSize, bar: CGRect, geometry: BarGeometry?, visibleFrame: CGRect) -> CGRect {
        let bottom = bar.maxY - (geometry?.visibleBottom ?? bar.height)
        let anchor = CGRect(x: bar.minX, y: bottom, width: bar.width, height: 0)
        let top = popupAttachmentTop(anchor: anchor, window: bar, geometry: geometry)
        let x = min(max(bar.midX - size.width / 2, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        return CGRect(x: x, y: max(visibleFrame.minY + 8, top - size.height - 8), width: size.width, height: size.height)
    }
}

@MainActor
final class ThemeTrialPanel {
    private let present: (PopupPanel) -> Void
    private var panel: PopupPanel?
    private var trial: ThemeTrial?
    private weak var bar: BarPanel?
    private var screen: NSScreen?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(present: @escaping (PopupPanel) -> Void = { $0.makeKeyAndOrderFront(nil) }) {
        self.present = present
    }

    func show(store: BarStore, bar: BarPanel, screen: NSScreen) {
        cancel()
        store.popup.close()
        let trial = ThemeTrial(store: store)
        let panel = PopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Try Themes"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.autorecalculatesKeyViewLoop = true
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.contentView = NSHostingView(rootView: ThemeTrialView(trial: trial, changed: { [weak self] in self?.synchronize() }))
        self.panel = panel
        self.trial = trial
        self.bar = bar
        self.screen = screen
        reposition()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        present(panel)
    }

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        if event.type == .keyDown {
            guard event.window === panel,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            let handled = trial?.handleKey(event.keyCode) ?? false
            if handled { synchronize() }
            return handled
        }
        if event.window !== panel { cancel() }
        return false
    }

    func reposition() {
        guard let panel, let bar, let screen, let host = panel.contentView else { return }
        panel.setFrame(ThemeTrialPlacement.frame(size: host.fittingSize, bar: bar.frame, geometry: bar.barGeometry,
                                                 visibleFrame: screen.visibleFrame), display: true)
    }

    private func synchronize() {
        if trial?.isActive == false { close() }
        else { reposition() }
    }

    func cancel() {
        trial?.cancel()
        close()
    }

    private func close() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        panel?.close()
        panel = nil
        trial = nil
        bar = nil
        screen = nil
    }
}

private struct ThemeTrialView: View {
    let trial: ThemeTrial
    let changed: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { trial.previous(); changed() } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous theme")
                    .help("Previous theme (←)")
                VStack(spacing: 3) {
                    Text(trial.choice?.title ?? "No themes available").font(.headline)
                    Text(trial.position).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(trial.choice?.title ?? "No themes available"), \(trial.position)")
                Button { trial.next(); changed() } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next theme")
                    .help("Next theme (→)")
            }
            if let error = trial.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { trial.cancel(); changed() }
                    .accessibilityLabel("Cancel trying themes")
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Keep") { trial.keep(); changed() }
                    .accessibilityLabel("Keep this theme")
                    .keyboardShortcut(.defaultAction)
                    .disabled(!trial.canKeep)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
