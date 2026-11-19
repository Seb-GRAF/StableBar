import SwiftUI

final class PassiveBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct NativeBarDecorations: NSViewRepresentable {
    let underlines: [WorkspaceUnderline]
    let size: CGSize
    let colorScheme: ColorScheme
    let displayScale: CGFloat

    func makeNSView(context: Context) -> BarDecorationView { BarDecorationView() }

    func updateNSView(_ view: BarDecorationView, context: Context) {
        let transaction = context.transaction
        view.content = AnyView(WorkspaceDecorationCanvas(underlines: underlines)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.colorScheme, colorScheme)
            .environment(\.displayScale, displayScale)
            .transaction { $0 = transaction })
        view.updatePanel()
    }

    static func dismantleNSView(_ view: BarDecorationView, coordinator: ()) {
        view.owner?.setDecorations(nil)
    }
}

final class BarDecorationView: NSView {
    var content: AnyView?
    weak var owner: BarPanel?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updatePanel() }

    func updatePanel() {
        guard let panel = window as? BarPanel else { return }
        owner = panel
        panel.setDecorations(content)
    }
}
