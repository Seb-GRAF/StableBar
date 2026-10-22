import AppKit
import Observation

/// Presence in the normal bar, kept separate from the temporary edit-mode reveal.
struct BarWidgetVisibility {
    enum Reason: String, Equatable {
        case display, output, workspaces
    }

    let reasons: [Reason]
    var isHidden: Bool { !reasons.isEmpty }
}

struct BarEditWidget: Identifiable {
    let widget: WidgetConfiguration
    let name: String
    let visibility: BarWidgetVisibility
    let usesPlaceholder: Bool
    var id: String { widget.id }
}

struct BarEditInsertion: Equatable {
    let displayID: Int
    let position: WidgetPosition
    let before: String?
    let index: Int
    let x: CGFloat
}

/// Editing never changes visibility, actions or enabled flags in the configuration.
@MainActor @Observable
final class BarEditing {
    private unowned let store: BarStore
    private(set) var isActive = false
    let dragSession = WidgetDragSession()
    let addPopover: BarEditAddPopover
    var insertion: BarEditInsertion?
    private(set) var dropped: (id: String, target: BarEditInsertion)?
    var error: String?
    private(set) var errorDisplayID: Int?
    private var measuredHeights: [Int: CGFloat] = [:]

    init(store: BarStore, addPopover: BarEditAddPopover = BarEditAddPopover()) {
        self.store = store
        self.addPopover = addPopover
    }

    var menuTitle: String { isActive ? "Finish Editing Bar" : "Edit Bar in Place" }
    var isAvailable: Bool { store.configuration != nil }
    var allowsWidgetActions: Bool { !isActive }

    func toggle() { if isActive { end() } else { begin() } }

    func begin() {
        guard isAvailable, !isActive else { return }
        store.onEndCustomizationEditing?()
        store.onEndThemeTrial?()
        store.endThemeTrial()
        store.popup.close()
        error = nil
        errorDisplayID = nil
        measuredHeights = [:]
        isActive = true
        store.onConfigurationChange?()
    }

    func end() {
        guard isActive else { return }
        addPopover.close(focusBar: false)
        if let payload = dragSession.active { dragSession.end(payload) }
        insertion = nil
        dropped = nil
        isActive = false
        error = nil
        errorDisplayID = nil
        measuredHeights = [:]
        store.onConfigurationChange?()
    }

    func screensChanged() { addPopover.close(focusBar: false) }

    @discardableResult
    func handleKey(_ keyCode: UInt16, characters: String? = nil, charactersIgnoringModifiers: String? = nil,
                   modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard isActive else { return false }
        if keyCode == 53, modifiers.isEmpty { end(); return true }
        let letters = [characters, charactersIgnoringModifiers].compactMap { $0?.lowercased() }
        let isZ = letters.contains("z") || (keyCode == 6 && !letters.contains { $0.contains { $0.isASCII && $0.isLetter } })
        guard isZ,
              modifiers == .command || modifiers == [.command, .shift] else { return false }
        if modifiers.contains(.shift) { redo() } else { undo() }
        return true
    }

    var canUndo: Bool { isActive && store.customizationHistory.canUndo }

    func undo() {
        guard isActive else { return }
        perform(on: store.activeDisplayID) { try store.customizationHistory.undo() }
    }

    func redo() {
        guard isActive else { return }
        perform(on: store.activeDisplayID) { try store.customizationHistory.redo() }
    }

    func visibility(of widget: WidgetConfiguration, on display: BarDisplay) -> BarWidgetVisibility {
        let presentation = store.presentations[widget.id]
        let activeID = store.workspaceStore.workspaces.first(where: \.isFocused)?.monitor ?? store.activeDisplayID
        var reasons: [BarWidgetVisibility.Reason] = []
        if !(presentation?.display ?? widget.display).includes(display, activeID: activeID) { reasons.append(.display) }
        if presentation?.hidden == true { reasons.append(.output) }
        if widget.content == .workspaces && widget.layout == nil && store.workspaceStore.error == nil
            && store.workspaceStore.workspaces(on: display.id, showEmpty: widget.workspace?.showEmpty == true).isEmpty {
            reasons.append(.workspaces)
        }
        return BarWidgetVisibility(reasons: reasons)
    }

    /// Turned-off widgets aren't on the bar, even while editing: removing a package or include
    /// widget turns it off, so it leaves the bar. Settings → Your bar can turn it on again.
    func widgets(on display: BarDisplay) -> [WidgetConfiguration] {
        (store.configuration?.onScreen(ScreenKind(display)).widgets ?? []).filter { $0.enabled && (isActive || !visibility(of: $0, on: display).isHidden) }
    }

    func entries(on display: BarDisplay) -> [BarEditWidget] {
        let widgets = widgets(on: display)
        let names = WidgetDisplayName.names(for: store.configuration?.widgets ?? [], packageNames: store.widgetPackageNames,
                                           providers: store.configuration?.providers ?? [:])
        return widgets.map { widget in
            let visibility = visibility(of: widget, on: display)
            let label = store.label(for: widget).overlaid(by: store.presentations[widget.id]?.temporaryFields)
            let output = store.scripts[widget.id]?.output
            let layout = widget.layout ?? widget.defaultLayout(label, output: output,
                                                               appIcon: widget.content == .activeApp && store.activeApp?.icon != nil,
                                                               providerType: store.configuration?.providerType(of: widget))
            let drawsCells = switch widget.content {
            case .workspaces, .appMenu, .appleMenu: true
            default: false
            }
            let hasContent = drawsCells && widget.layout == nil
                || layout.map { BarEditContent.hasContent($0, fields: label.fields, output: output,
                                                          menu: output?.menu ?? widget.menu ?? []) } == true
            let transparent = store.presentations[widget.id]?.style(on: ScreenKind(display)).base.opacity == 0
            return BarEditWidget(widget: widget, name: names[widget.id] ?? widget.id, visibility: visibility,
                                 usesPlaceholder: visibility.isHidden || !hasContent || transparent)
        }
    }

    func geometry(for display: BarDisplay) -> BarGeometry? {
        guard let config = store.configuration?.onScreen(ScreenKind(display)) else { return nil }
        guard isActive, let height = measuredHeights[display.id] else { return config.barGeometry(for: display) }
        return BarGeometry(layoutHeight: max(config.bar.height * CGFloat(config.bar.scale(for: display)), height + 2 * config.bar.margin),
                           margin: config.bar.margin, outsideExtent: 0)
    }

    func trayState(on displayID: Int, position: WidgetPosition) -> BarEditTrayState {
        let dragging = dragSession.active != nil
        return BarEditTrayState(showsName: dragging, showsBadges: !dragging,
                                isTarget: dragging && insertion?.displayID == displayID && insertion?.position == position)
    }

    func isMoving(_ id: String) -> Bool {
        guard let movingID = dragSession.active?.widgetID ?? dropped?.id, let widgets = store.configuration?.widgets,
              let moving = widgets.first(where: { $0.id == movingID }),
              let widget = widgets.first(where: { $0.id == id }) else { return false }
        return widget.id == moving.id || (moving.group != nil && moving.group == widget.group)
    }

    func opacity(for id: String) -> Double { dragSession.active != nil && isMoving(id) ? 0 : 1 }

    func arranged(_ entries: [BarEditWidget], on displayID: Int, position: WidgetPosition) -> [BarEditWidget] {
        let tray = entries.filter { $0.widget.position == position }
        guard let insertion, insertion.displayID == displayID, insertion.position == position else { return tray }
        var arranged = tray.filter { !isMoving($0.id) }
        arranged.insert(contentsOf: entries.filter { isMoving($0.id) },
                        at: arranged.firstIndex { $0.id == insertion.before } ?? arranged.endIndex)
        return arranged
    }

    func isCollapsed(_ id: String, on displayID: Int, position: WidgetPosition) -> Bool {
        guard let insertion else { return false }
        return isMoving(id) && (insertion.displayID != displayID || insertion.position != position)
    }

    func measure(height: CGFloat, on displayID: Int) {
        guard isActive, height.isFinite, height > 0 else { return }
        let height = ceil(height)
        guard measuredHeights[displayID] != height else { return }
        measuredHeights[displayID] = height
        store.onConfigurationChange?()
    }

    /// Frames and pointer share the section viewport's coordinates, including its scroll offset.
    /// Groups are one insertion target, even when a member's frame is missing.
    func dropTarget(_ id: String, on displayID: Int, position: WidgetPosition, x: CGFloat,
                    frames: [String: CGRect]) -> BarEditInsertion? {
        guard isActive, let shared = store.configuration else { return nil }
        let configuration = screenKind(displayID).map(shared.onScreen) ?? shared
        return WidgetPlacement.dropTarget(id, on: displayID, position: position, x: x, frames: frames,
                                          widgets: configuration.widgets, groups: configuration.groups)
    }

    @discardableResult
    func drop(_ payload: WidgetDragSession.Payload, at target: BarEditInsertion) -> Bool {
        guard isActive else { return false }
        return dragSession.drop(payload) { id in
            insertion = target
            dropped = (id, target)
        }
    }

    func finishDrop() {
        guard let dropped else { return }
        self.dropped = nil
        move(dropped.id, to: dropped.target.position, before: dropped.target.before, on: dropped.target.displayID)
        insertion = nil
    }

    func move(_ id: String, to position: WidgetPosition, before anchor: String? = nil, on displayID: Int? = nil) {
        guard isActive else { return }
        perform(on: displayID) { try WidgetSetup(store: store).move(id, to: position, before: anchor, on: screenKind(displayID)) }
    }

    func move(_ id: String, by offset: Int, on displayID: Int? = nil) {
        guard isActive else { return }
        // Step over the turned-off widgets the bar leaves out.
        perform(on: displayID) { try WidgetSetup(store: store).move(id, by: offset, on: screenKind(displayID), listed: \.enabled) }
    }

    func remove(_ id: String, on displayID: Int? = nil) {
        guard isActive else { return }
        perform(on: displayID) { try WidgetSetup(store: store).remove(id) }
    }

    func set(_ id: String, _ properties: [String: ConfigurationValue], on displayID: Int) {
        perform(on: displayID) {
            try store.customizationHistory.change(ConfigurationEdit(action: .set, id: id, properties: properties))
        }
    }

    func select(_ id: String) {
        guard isActive, store.configuration?.widgets.contains(where: { $0.id == id }) == true else { return }
        store.onCustomizeWidget?(id)
    }

    private func screenKind(_ displayID: Int?) -> ScreenKind? {
        NSScreen.screens.map(BarDisplay.init).first { $0.id == displayID }.map(ScreenKind.init)
    }

    private func perform(on displayID: Int?, _ action: () throws -> Void) {
        store.onEndCustomizationEditing?()
        do { try action(); error = nil; errorDisplayID = nil }
        catch { report(error, on: displayID) }
    }

    func report(_ error: Error, on displayID: Int?) {
        self.error = errorMessage(error)
        errorDisplayID = displayID
    }
}

private enum BarEditContent {
    static func hasContent(_ block: PopupBlock, fields: [String: String], output: ScriptOutput?, menu: [WidgetMenuItem]) -> Bool {
        if let field = block.hideWhenEmpty, fields[field, default: ""].isEmpty { return false }
        switch block.content {
        case let .row(children), let .column(children):
            return children.contains { hasContent($0, fields: fields, output: output, menu: menu) }
        case let .text(text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .field(name): return fields[name] == nil || fields[name]?.isEmpty == false
        case let .symbol(name, source): return !(source.flatMap { fields[$0] } ?? name).isEmpty
        case let .image(path, source, _): return !(source.flatMap { fields[$0] } ?? path).isEmpty
        case let .list(source, row):
            return output?.lists?[source]?.contains { hasContent(row, fields: $0, output: output, menu: menu) } == true
        case .menu: return !menu.isEmpty
        default: return true
        }
    }
}

enum BarEditTrayMetrics {
    static let slot: CGFloat = 22
    static let horizontalPadding: CGFloat = 7
    static let verticalPadding: CGFloat = 6
    static let emptyWidth = slot + 2 * horizontalPadding

    static func chipWidth(for position: WidgetPosition) -> CGFloat {
        ceil((position.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold)]).width) + 18
    }
}

struct BarEditTrayState: Equatable {
    let showsName: Bool
    let showsBadges: Bool
    let isTarget: Bool
    var showsAddSlot: Bool { !isTarget }
}

/// The normal planner supplies screen order and centering. Only trays wider than
/// their share of the available space scroll.
struct BarEditLayout {
    let sections: [WidgetPosition: BarPlacement]
    let scrolling: Set<WidgetPosition>

    init(width: CGFloat, display: BarDisplay, bar: BarSettings, preferredWidths: [WidgetPosition: CGFloat] = [:]) {
        let scale = CGFloat(bar.scale(for: display))
        let inset = max(6, CGFloat(bar.inset) * scale)
        let spacing: CGFloat = 6 * scale
        let notch = display.notch.map { range in
            let center: CGFloat = (range.lowerBound + range.upperBound) / 2 - CGFloat(bar.margin)
            let half: CGFloat = bar.notchWidth.map { CGFloat($0) * scale / 2 } ?? (range.upperBound - range.lowerBound) / 2
            return (center - half)...(center + half)
        }
        let content = Dictionary(uniqueKeysWithValues: WidgetPosition.allCases.map {
            ($0, max(1, preferredWidths[$0] ?? BarEditTrayMetrics.emptyWidth * scale))
        })
        let preferred = Dictionary(uniqueKeysWithValues: WidgetPosition.allCases.map {
            ($0, max(content[$0]!, BarEditTrayMetrics.chipWidth(for: $0) * scale))
        })
        var widths = preferred
        let notchSpacing = CGFloat(bar.notchSpacing) * scale
        if let notch {
            Self.fit([.left, .notchLeft], capacity: max(inset, notch.lowerBound - notchSpacing) - inset - spacing,
                     content: content, widths: &widths)
            Self.fit([.notchRight, .center, .right],
                     capacity: width - inset - min(width - inset, notch.upperBound + notchSpacing) - 2 * spacing,
                     content: content, widths: &widths)
        } else {
            Self.fit(WidgetPosition.allCases, capacity: width - 2 * inset - 4 * spacing, content: content, widths: &widths)
        }
        let items = WidgetPosition.allCases.map { position in
            BarLayoutItem(id: position.rawValue, position: position,
                          width: widths[position]!, canOverflow: false)
        }
        let plan = AdaptiveBarPlanner(inset: inset, spacing: spacing, notchSpacing: notchSpacing, notch: notch)
            .plan(width: width, items: items)
        let sections = Dictionary(uniqueKeysWithValues: WidgetPosition.allCases.compactMap { position in
            plan.placements[position.rawValue].map { (position, $0) }
        })
        self.sections = sections
        scrolling = Set(WidgetPosition.allCases.filter { sections[$0]!.width < content[$0]! - 0.5 })
    }

    private static func fit(_ positions: [WidgetPosition], capacity: CGFloat, content: [WidgetPosition: CGFloat],
                            widths: inout [WidgetPosition: CGFloat]) {
        // Shorten a drag chip before scrolling content that would otherwise fit.
        let excess = max(0, positions.reduce(CGFloat.zero) { $0 + widths[$1]! } - max(0, capacity))
        let slack = positions.reduce(CGFloat.zero) { $0 + max(0, widths[$1]! - content[$1]!) }
        if slack > 0 {
            for position in positions { widths[position]! -= (widths[position]! - content[position]!) * min(1, excess / slack) }
        }
        var remaining = max(0, capacity)
        for (index, position) in positions.sorted(by: { widths[$0]! < widths[$1]! }).enumerated() {
            let width = min(widths[position]!, remaining / CGFloat(positions.count - index))
            widths[position] = width
            remaining -= width
        }
    }
}

struct BarEditOverflow: Equatable {
    let leading: Bool
    let trailing: Bool

    init(bounds: CGRect, viewportWidth: CGFloat) {
        leading = !bounds.isNull && bounds.minX < -0.5
        trailing = !bounds.isNull && bounds.maxX > viewportWidth + 0.5
    }

    static func offset(from current: CGFloat, deltaX: CGFloat, deltaY: CGFloat, precise: Bool,
                       contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        let delta = abs(deltaX) > abs(deltaY) ? deltaX : deltaY
        return min(max(0, current - delta * (precise ? 1 : 10)), max(0, contentWidth - viewportWidth))
    }
}
