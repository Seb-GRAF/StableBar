import AppKit
import SwiftUI

@MainActor
class BarEditControlsPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Edit Bar"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class BarEditControls: NSObject {
    private struct Controls {
        let bar: BarPanel
        let panel: BarEditControlsPanel
        var hasSheet: Bool
    }

    private let makePanel: () -> BarEditControlsPanel
    private var controls: [CGDirectDisplayID: Controls] = [:]

    init(makePanel: @escaping () -> BarEditControlsPanel = { BarEditControlsPanel() }) {
        self.makePanel = makePanel
        super.init()
    }

    func update(store: BarStore, bars: [CGDirectDisplayID: BarPanel], visibleFrames: [CGDirectDisplayID: CGRect]) {
        guard store.barEditing.isActive else { close(); return }
        for (id, entry) in controls where bars[id] !== entry.bar || visibleFrames[id] == nil {
            close(id)
        }
        for (id, bar) in bars {
            guard let visibleFrame = visibleFrames[id] else { continue }
            if controls[id] == nil {
                let panel = makePanel()
                let host = NSHostingView(rootView: BarEditControlsView(editing: store.barEditing))
                panel.contentView = host
                controls[id] = Controls(bar: bar, panel: panel, hasSheet: bar.attachedSheet != nil)
                NotificationCenter.default.addObserver(self, selector: #selector(willBeginSheet),
                                                       name: NSWindow.willBeginSheetNotification, object: bar)
                NotificationCenter.default.addObserver(self, selector: #selector(didEndSheet),
                                                       name: NSWindow.didEndSheetNotification, object: bar)
            }
            guard let entry = controls[id], let host = entry.panel.contentView else { continue }
            entry.panel.level = bar.level
            entry.panel.collectionBehavior = bar.collectionBehavior
            let fittingSize = host.fittingSize
            let size = CGSize(width: min(fittingSize.width, max(0, visibleFrame.width - 16)), height: fittingSize.height)
            entry.panel.setFrame(ThemeTrialPlacement.frame(size: size, bar: bar.frame, geometry: bar.barGeometry,
                                                          visibleFrame: visibleFrame), display: true)
            if entry.hasSheet || bar.attachedSheet != nil { entry.panel.orderOut(nil) }
            else { entry.panel.orderFrontRegardless() }
        }
    }

    @objc private func willBeginSheet(_ notification: Notification) {
        guard let bar = notification.object as? BarPanel,
              let id = controls.first(where: { $0.value.bar === bar })?.key else { return }
        controls[id]?.hasSheet = true
        controls[id]?.panel.orderOut(nil)
    }

    @objc private func didEndSheet(_ notification: Notification) {
        guard let bar = notification.object as? BarPanel,
              let id = controls.first(where: { $0.value.bar === bar })?.key else { return }
        controls[id]?.hasSheet = false
        if bar.isEditingBar && bar.attachedSheet == nil { controls[id]?.panel.orderFrontRegardless() }
    }

    private func close(_ id: CGDirectDisplayID) {
        guard let entry = controls.removeValue(forKey: id) else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willBeginSheetNotification, object: entry.bar)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didEndSheetNotification, object: entry.bar)
        entry.panel.close()
    }

    func close() {
        for id in Array(controls.keys) { close(id) }
    }
}

private struct BarEditControlsView: View {
    let editing: BarEditing

    var body: some View {
        HStack(spacing: 12) {
            Text("Drag to move · − removes · click a widget to change it")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Undo", action: editing.undo)
                .accessibilityLabel("Undo bar change")
                .help("Undo (⌘Z)")
                .disabled(!editing.canUndo)
                .fixedSize()
            Button("Done", action: editing.end)
                .accessibilityLabel("Finish editing the bar")
                .help("Finish editing the bar (Esc)")
                .buttonStyle(.borderedProminent)
                .fixedSize()
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
