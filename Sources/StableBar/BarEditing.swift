import AppKit
import Observation

/// Presence in the normal bar, kept separate from the temporary edit-mode reveal.
struct BarWidgetVisibility {
    enum Reason: String, Equatable {
        case disabled, display, output, workspaces
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
    var insertion: BarEditInsertion?
    var error: String?
    private(set) var errorDisplayID: Int?

    init(store: BarStore) { self.store = store }

    var menuTitle: String { isActive ? "Finish Editing Bar" : "Edit Bar" }
    var isAvailable: Bool { !store.isPreview && store.configuration != nil }
    var allowsWidgetActions: Bool { !store.isPreview && !isActive }

    func toggle() { if isActive { end() } else { begin() } }

    func begin() {
        guard isAvailable, !isActive else { return }
        store.onEndCustomizationEditing?()
        store.onEndThemeTrial?()
        store.endThemeTrial()
        store.popup.close()
        error = nil
        errorDisplayID = nil
        isActive = true
        store.onConfigurationChange?()
    }

    func end() {
        guard isActive else { return }
        if let payload = dragSession.active { dragSession.end(payload) }
        insertion = nil
        isActive = false
        error = nil
        errorDisplayID = nil
        store.onConfigurationChange?()
    }

    @discardableResult
    func handleKey(_ keyCode: UInt16) -> Bool {
        guard isActive, keyCode == 53 else { return false }
        end()
        return true
    }

    func visibility(of widget: WidgetConfiguration, on display: BarDisplay) -> BarWidgetVisibility {
        let presentation = store.presentations[widget.id]
        let activeID = store.workspaceStore.workspaces.first(where: \.isFocused)?.monitor ?? store.activeDisplayID
        var reasons: [BarWidgetVisibility.Reason] = []
        if !widget.enabled { reasons.append(.disabled) }
        if !(presentation?.display ?? widget.display).includes(display, activeID: activeID) { reasons.append(.display) }
        if presentation?.hidden == true { reasons.append(.output) }
        if widget.content == .workspaces && widget.layout == nil && store.workspaceStore.error == nil
            && store.workspaceStore.workspaces(on: display.id, showEmpty: widget.workspace?.showEmpty == true).isEmpty {
            reasons.append(.workspaces)
        }
        return BarWidgetVisibility(reasons: reasons)
    }

    func widgets(on display: BarDisplay) -> [WidgetConfiguration] {
        (store.configuration?.widgets ?? []).filter { isActive || !visibility(of: $0, on: display).isHidden }
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
                                                               appIcon: widget.content == .activeApp && store.activeApp?.icon != nil)
            let hasContent = widget.content == .workspaces && widget.layout == nil
                || layout.map { BarEditContent.hasContent($0, fields: label.fields, output: output,
                                                          menu: output?.menu ?? widget.menu ?? []) } == true
            let transparent = store.presentations[widget.id]?.style.base.opacity == 0
            return BarEditWidget(widget: widget, name: names[widget.id] ?? widget.id, visibility: visibility,
                                 usesPlaceholder: visibility.isHidden || !hasContent || transparent)
        }
    }

    func geometry(for display: BarDisplay) -> BarGeometry? {
        guard let config = store.configuration else { return nil }
        if !isActive { return config.barGeometry(for: display) }
        return BarGeometry(layoutHeight: max(config.bar.height * config.bar.scale(for: display), 84 + 2 * config.bar.margin),
                           margin: config.bar.margin, outsideExtent: 0)
    }

    /// Frames and pointer share the section viewport's coordinates, including its scroll offset.
    /// Groups are one insertion target, even when a member's frame is missing.
    func dropTarget(_ id: String, on displayID: Int, position: WidgetPosition, x: CGFloat,
                    frames: [String: CGRect]) -> BarEditInsertion? {
        guard isActive, let config = store.configuration,
              let moving = config.widgets.first(where: { $0.id == id }) else { return nil }
        let remaining = config.widgets.filter {
            $0.position == position && $0.id != id && (moving.group == nil || $0.group != moving.group)
        }
        let units = BarUnit.make(widgets: remaining, groups: config.groups)
        var index = 0
        var end: CGFloat = 8
        for unit in units {
            let bounds = unit.widgets.compactMap { frames[$0.id] }.reduce(CGRect.null) { $0.union($1) }
            guard !bounds.isNull else { index += unit.widgets.count; continue }
            if x < bounds.midX {
                return BarEditInsertion(displayID: displayID, position: position, before: unit.widgets[0].id,
                                        index: index, x: bounds.minX - 3)
            }
            end = bounds.maxX + 3
            index += unit.widgets.count
        }
        return BarEditInsertion(displayID: displayID, position: position, before: nil, index: remaining.count, x: end)
    }

    @discardableResult
    func drop(_ payload: WidgetDragSession.Payload, at target: BarEditInsertion) -> Bool {
        guard isActive else { return false }
        defer { insertion = nil }
        return dragSession.drop(payload) { id in move(id, to: target.position, before: target.before, on: target.displayID) }
    }

    func move(_ id: String, to position: WidgetPosition, before anchor: String? = nil, on displayID: Int? = nil) {
        guard isActive else { return }
        perform(on: displayID) { try WidgetSetup(store: store).move(id, to: position, before: anchor) }
    }

    func move(_ id: String, by offset: Int, on displayID: Int? = nil) {
        guard isActive else { return }
        perform(on: displayID) { try WidgetSetup(store: store).move(id, by: offset) }
    }

    func remove(_ id: String, on displayID: Int? = nil) {
        guard isActive else { return }
        perform(on: displayID) { try WidgetSetup(store: store).remove(id) }
    }

    func select(_ id: String) {
        guard isActive, store.configuration?.widgets.contains(where: { $0.id == id }) == true else { return }
        store.onCustomizeWidget?(id)
    }

    private func perform(on displayID: Int?, _ action: () throws -> Void) {
        store.onEndCustomizationEditing?()
        do { try action(); error = nil; errorDisplayID = nil }
        catch { self.error = errorMessage(error); errorDisplayID = displayID }
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

/// All five positions stay reachable. The normal planner supplies their actual screen order
/// and centering; each section scrolls instead of overflowing its widgets.
struct BarEditLayout {
    let sections: [WidgetPosition: BarPlacement]
    let done: BarPlacement

    init(width: CGFloat, display: BarDisplay, bar: BarSettings, preferredWidths: [WidgetPosition: CGFloat] = [:]) {
        let scale = CGFloat(bar.scale(for: display))
        let inset = max(6, CGFloat(bar.inset) * scale)
        let spacing: CGFloat = 6
        let doneWidth: CGFloat = 54
        let doneSpace = doneWidth + spacing
        let notch = display.notch.map { range in
            let center: CGFloat = (range.lowerBound + range.upperBound) / 2 - CGFloat(bar.margin)
            let half: CGFloat = bar.notchWidth.map { CGFloat($0) * scale / 2 } ?? (range.upperBound - range.lowerBound) / 2
            return (center - half)...(center + half)
        }
        let items = WidgetPosition.allCases.map { position in
            BarLayoutItem(id: position.rawValue, position: position,
                          width: max(118, preferredWidths[position] ?? 118) + (position == .right ? doneSpace : 0), canOverflow: false)
        }
        let plan = AdaptiveBarPlanner(inset: inset, spacing: spacing, notchSpacing: CGFloat(bar.notchSpacing) * scale, notch: notch)
            .plan(width: width, items: items)
        sections = Dictionary(uniqueKeysWithValues: WidgetPosition.allCases.compactMap { position in
            plan.placements[position.rawValue].map {
                (position, BarPlacement(x: $0.x, width: max(0, $0.width - (position == .right ? doneSpace : 0))))
            }
        })
        done = BarPlacement(x: max(0, width - inset - doneWidth), width: doneWidth)
    }
}
