import AppKit
import SwiftUI

struct BarPreview: View {
    let store: BarStore
    let kind: ScreenKind
    let names: [String: String]
    let selected: String?
    let select: (String?) -> Void
    let session: WidgetDragSession
    let move: (String, WidgetPosition, String?) -> Void
    @State private var insertion: BarEditInsertion?
    @State private var hovered: String?

    var body: some View {
        GeometryReader { geometry in
            let screen = kind.display
            let notch = screen.notch.map { $0.upperBound - $0.lowerBound }
            let display = BarDisplay(id: screen.id, isBuiltIn: screen.isBuiltIn, isMain: screen.isMain,
                                     notch: notch.map { (geometry.size.width - $0) / 2...(geometry.size.width + $0) / 2 },
                                     isPortrait: screen.isPortrait)
            let height = store.configuration?.barGeometry(for: display).layoutHeight ?? 0
            ZStack(alignment: .top) {
                Wallpaper()
                BarView(store: store, display: display, preview: true)
                    .allowsHitTesting(false)
                    .overlayPreferenceValue(BarAnchorPreference.self) { anchors in
                        GeometryReader { proxy in
                            if let configuration = store.configuration {
                                let frames = anchors.widgets.mapValues { proxy[$0.bounds] }
                                let layout = BarPreviewLayout(configuration: configuration, display: display,
                                                              frames: frames, size: proxy.size)
                                BarPreviewInteraction(session: session, layout: layout, names: names, select: select,
                                                      insert: { if insertion != $0 { insertion = $0 } }, move: move) {
                                    ZStack(alignment: .topLeading) {
                                        ForEach(configuration.widgets.filter { frames[$0.id] != nil }) { widget in
                                            outline(widget, frame: frames[widget.id]!)
                                        }
                                        if session.active != nil {
                                            ForEach(layout.positions, id: \.self) { position in
                                                let region = layout.region(for: position)
                                                Text(position.title)
                                                    .font(.system(size: 9, weight: .medium))
                                                    .foregroundStyle(insertion?.position == position ? Color.accentColor : .secondary)
                                                    .frame(width: region.width, height: 20)
                                                    .background(insertion?.position == position ? Color.accentColor.opacity(0.15) : .clear)
                                                    .position(x: region.midX, y: proxy.size.height - 10)
                                            }
                                            if let insertion {
                                                Rectangle().fill(Color.accentColor).frame(width: 3, height: max(18, height - 4))
                                                    .position(x: insertion.x, y: height / 2)
                                            }
                                        }
                                    }
                                    .frame(width: proxy.size.width, height: proxy.size.height)
                                }
                            }
                        }
                    }
                    .padding(.top, min(store.configuration?.onScreen(kind).bar.offset ?? 0, max(0, geometry.size.height - height)))
                if let notch {
                    UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11)
                        .fill(.black)
                        .frame(width: notch, height: kind.screens.first?.safeAreaInsets.top ?? 30)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(SettingsPalette.groupBorder))
        .help("Click a widget to edit it, or drag to move it")
        .onChange(of: session.active) { if session.active == nil { insertion = nil } }
    }

    private func outline(_ widget: WidgetConfiguration, frame: CGRect) -> some View {
        let id = widget.id
        let configuration = store.configuration!
        let radius = resolveStyle([configuration.defaults, configuration.roleStyle(widget.role), widget.style]).cornerRadius ?? 0
        return RoundedRectangle(cornerRadius: radius + 3)
            .strokeBorder(id == selected ? Color.accentColor : .white.opacity(id == hovered ? 0.65 : 0),
                          style: StrokeStyle(lineWidth: id == selected ? 2 : 1, dash: id == selected ? [] : [3, 2]))
            .padding(-3)
            .contentShape(Rectangle())
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .onHover { hovered = $0 ? id : hovered == id ? nil : hovered }
            .accessibilityElement()
            .accessibilityLabel(names[id] ?? id)
            .accessibilityAddTraits(id == selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select(id) }
    }
}

struct BarPreviewLayout {
    let configuration: Configuration
    let display: BarDisplay
    let frames: [String: CGRect]
    let size: CGSize
    private var widgets: [WidgetConfiguration] { configuration.onScreen(ScreenKind(display)).widgets }

    var positions: [WidgetPosition] {
        WidgetPlacement.positions(widgets: widgets, hasNotchedDisplay: display.notch != nil)
    }

    func widget(at point: CGPoint) -> String? {
        widgets.first { frames[$0.id]?.contains(point) == true }?.id
    }

    func region(for position: WidgetPosition) -> CGRect {
        let width = size.width / CGFloat(positions.count)
        return CGRect(x: CGFloat(positions.firstIndex(of: position)!) * width, y: size.height - 20, width: width, height: 20)
    }

    func target(_ id: String, at point: CGPoint) -> BarEditInsertion? {
        let position: WidgetPosition
        if point.y >= size.height - 20 {
            position = positions.first { region(for: $0).contains(point) } ?? positions.last!
        } else if let hovered = widget(at: point) {
            position = widgets.first { $0.id == hovered }!.position
        } else {
            let bounds = Dictionary(uniqueKeysWithValues: positions.map { position in
                (position, widgets.filter { $0.position == position }
                    .compactMap { frames[$0.id] }.reduce(CGRect.null) { $0.union($1) })
            })
            position = positions.min {
                let left = bounds[$0]!.isNull ? region(for: $0).midX : bounds[$0]!.midX
                let right = bounds[$1]!.isNull ? region(for: $1).midX : bounds[$1]!.midX
                return abs(point.x - left) < abs(point.x - right)
            }!
        }
        guard let target = WidgetPlacement.dropTarget(id, on: display.id, position: position,
                                                     x: point.x, frames: frames, widgets: widgets, groups: configuration.groups) else { return nil }
        if !widgets.contains(where: { $0.position == position && frames[$0.id] != nil }) {
            return BarEditInsertion(displayID: display.id, position: position, before: target.before,
                                    index: target.index, x: region(for: position).midX)
        }
        return target
    }
}

private struct BarPreviewInteraction<Content: View>: NSViewRepresentable {
    let session: WidgetDragSession
    let layout: BarPreviewLayout
    let names: [String: String]
    let select: (String?) -> Void
    let insert: (BarEditInsertion?) -> Void
    let move: (String, WidgetPosition, String?) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> BarPreviewInteractionView {
        let view = BarPreviewInteractionView(rootView: AnyView(content()))
        view.registerForDraggedTypes([WidgetDragSourceView.pasteboardType])
        return view
    }

    func updateNSView(_ view: BarPreviewInteractionView, context: Context) {
        view.rootView = AnyView(content())
        view.session = session
        view.layout = layout
        view.names = names
        view.select = select
        view.insert = insert
        view.move = move
    }
}

final class BarPreviewInteractionView: WidgetDragSourceView {
    var session: WidgetDragSession?
    var layout: BarPreviewLayout?
    var names: [String: String] = [:]
    var select: (String?) -> Void = { _ in }
    var insert: (BarEditInsertion?) -> Void = { _ in }
    var move: (String, WidgetPosition, String?) -> Void = { _, _, _ in }
    private var pressedWidget: String?
    override var isFlipped: Bool { true }
    override var dragSession: WidgetDragSession? { session }
    override var dragWidgetID: String? { pressedWidget }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let event = NSApp?.currentEvent, ![NSEvent.EventType.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type) {
            return hit
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        pressedWidget = layout?.widget(at: convert(event.locationInWindow, from: nil))
        name = pressedWidget.map { names[$0] ?? $0 } ?? ""
        select(pressedWidget)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let payload = acceptedPayload(sender), let target = target(sender, payload: payload) else { return [] }
        insert(target)
        let key = target.position.rawValue + "/" + (target.before ?? "")
        if session?.insertion != key { session?.insertion = key }
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        insert(nil)
        session?.insertion = nil
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { acceptedPayload(sender) != nil }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let payload = acceptedPayload(sender), let target = target(sender, payload: payload) else { return false }
        insert(nil)
        return session?.drop(payload) { move($0, target.position, target.before) } ?? false
    }

    override func dragImage() -> NSImage { dragChip() }

    override func didEndWidgetDrag() { insert(nil) }

    private func target(_ sender: any NSDraggingInfo, payload: WidgetDragSession.Payload) -> BarEditInsertion? {
        layout?.target(payload.widgetID, at: convert(sender.draggingLocation, from: nil))
    }

    private func acceptedPayload(_ sender: any NSDraggingInfo) -> WidgetDragSession.Payload? {
        guard let source = sender.draggingSource as? WidgetDragSourceView,
              let data = sender.draggingPasteboard.data(forType: Self.pasteboardType) else { return nil }
        return session?.payload(from: data, source: source.dragSession)
    }
}
