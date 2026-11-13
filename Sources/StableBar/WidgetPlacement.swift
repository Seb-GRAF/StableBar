import Foundation

/// Shared by Customize and editing directly on the bar. The insertion anchor is in the
/// original list; dropping on a group inserts before the whole group.
enum WidgetPlacement {
    static let destinations = WidgetPosition.allCases

    static func positions(widgets: [WidgetConfiguration], hasNotchedDisplay: Bool) -> [WidgetPosition] {
        let usesNotch = hasNotchedDisplay || widgets.contains { [.notchLeft, .notchRight].contains($0.position) }
        return WidgetPosition.allCases.filter { position in
            usesNotch || ![.notchLeft, .notchRight].contains(position)
        }
    }

    /// Where a widget dropped at `x` lands among `frames`; the dragged widget is never an anchor.
    static func dropTarget(_ id: String, on displayID: Int, position: WidgetPosition, x: CGFloat,
                           frames: [String: CGRect], widgets: [WidgetConfiguration],
                           groups: [String: WidgetGroupConfiguration]) -> BarEditInsertion? {
        guard let moving = widgets.first(where: { $0.id == id }) else { return nil }
        let remaining = widgets.filter {
            $0.position == position && $0.id != id && (moving.group == nil || $0.group != moving.group)
        }
        let units = BarUnit.make(widgets: remaining, groups: groups)
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

    /// The position whose span on the bar is nearest to `x`.
    static func position(at x: CGFloat, in spans: [WidgetPosition: ClosedRange<CGFloat>]) -> WidgetPosition? {
        spans.min { distance(from: x, to: $0.value) < distance(from: x, to: $1.value) }?.key
    }

    private static func distance(from x: CGFloat, to span: ClosedRange<CGFloat>) -> CGFloat {
        max(span.lowerBound - x, x - span.upperBound, 0)
    }

    static func destination(selectedID: String?, widgets: [WidgetConfiguration]) -> WidgetPosition {
        widgets.first { $0.id == selectedID }?.position ?? .right
    }

    static func addAnchor(at position: WidgetPosition, widgets: [WidgetConfiguration]) -> String? {
        [.right, .notchLeft].contains(position) ? widgets.first { $0.position == position }?.id : nil
    }

    static func insertionIndex(at position: WidgetPosition, before anchor: String?, widgets: [WidgetConfiguration]) -> Int {
        if let target = widgets.first(where: { $0.id == anchor && $0.position == position }) {
            return widgets.firstIndex { $0.id == target.id || (target.group != nil && $0.group == target.group) }!
        }
        return widgets.lastIndex { $0.position == position }.map { $0 + 1 } ?? widgets.endIndex
    }

    static func move(_ id: String, by offset: Int, widgets: [WidgetConfiguration],
                     listed: (WidgetConfiguration) -> Bool = { _ in true }) throws -> [ConfigurationEdit] {
        edits(from: widgets, to: try arrangement(moving: id, by: offset, widgets: widgets, listed: listed))
    }

    static func move(_ id: String, to position: WidgetPosition, before anchor: String? = nil,
                     widgets: [WidgetConfiguration]) throws -> [ConfigurationEdit] {
        edits(from: widgets, to: try arrangement(moving: id, to: position, before: anchor, widgets: widgets))
    }

    /// `listed` picks the widgets the surface shows. A move steps over the others and leaves them in place.
    static func arrangement(moving id: String, by offset: Int, widgets: [WidgetConfiguration],
                            listed: (WidgetConfiguration) -> Bool = { _ in true }) throws -> [WidgetConfiguration] {
        guard let widget = widgets.first(where: { $0.id == id }) else {
            throw CommandFailure(message: "This widget is no longer available.")
        }
        let moves = { (other: WidgetConfiguration) in other.id == id || (widget.group != nil && other.group == widget.group) }
        let section = widgets.filter { $0.position == widget.position && (moves($0) || listed($0)) }
        let indices = section.indices.filter { moves(section[$0]) }
        guard let start = indices.first, let end = indices.last else { return widgets }
        if offset < 0, start > 0 { return try arrangement(moving: id, to: widget.position, before: section[start - 1].id, widgets: widgets) }
        if offset > 0, end + 1 < section.count {
            let next = section[end + 1]
            let following = section.dropFirst(end + 2).first { next.group == nil || $0.group != next.group }
            return try arrangement(moving: id, to: widget.position, before: following?.id, widgets: widgets)
        }
        return widgets
    }

    static func arrangement(moving id: String, to position: WidgetPosition, before anchor: String? = nil,
                            widgets: [WidgetConfiguration]) throws -> [WidgetConfiguration] {
        guard let widget = widgets.first(where: { $0.id == id }) else {
            throw CommandFailure(message: "This widget is no longer available.")
        }
        let moving = widgets.filter { $0.id == id || (widget.group != nil && $0.group == widget.group) }
        let movingIDs = Set(moving.map(\.id))
        if let anchor, movingIDs.contains(anchor), moving.allSatisfy({ $0.position == position }) { return widgets }
        var remaining = widgets.filter { !movingIDs.contains($0.id) }
        let insertion = insertionIndex(at: position, before: anchor, widgets: remaining)
        remaining.insert(contentsOf: moving.map { widget in
            var widget = widget
            widget.position = position
            return widget
        }, at: insertion)
        return remaining
    }

    private static func edits(from widgets: [WidgetConfiguration], to arrangement: [WidgetConfiguration]) -> [ConfigurationEdit] {
        var edits = arrangement.filter { widget in widgets.first { $0.id == widget.id }!.position != widget.position }.map {
            ConfigurationEdit(action: .set, id: $0.id, properties: ["position": .string($0.position.rawValue)])
        }
        let ids = arrangement.map(\.id)
        if ids != widgets.map(\.id) { edits.append(ConfigurationEdit(action: .reorder, ids: ids)) }
        return edits
    }
}
