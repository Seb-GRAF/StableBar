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

    /// `listed` picks the widgets the surface shows. A move steps over the others and leaves them in place.
    static func move(_ id: String, by offset: Int, widgets: [WidgetConfiguration],
                     listed: (WidgetConfiguration) -> Bool = { _ in true }) throws -> [ConfigurationEdit] {
        guard let widget = widgets.first(where: { $0.id == id }) else {
            throw CommandFailure(message: "This widget is no longer available.")
        }
        let moves = { (other: WidgetConfiguration) in other.id == id || (widget.group != nil && other.group == widget.group) }
        let section = widgets.filter { $0.position == widget.position && (moves($0) || listed($0)) }
        let indices = section.indices.filter { moves(section[$0]) }
        guard let start = indices.first, let end = indices.last else { return [] }
        if offset < 0, start > 0 { return try move(id, to: widget.position, before: section[start - 1].id, widgets: widgets) }
        if offset > 0, end + 1 < section.count {
            let next = section[end + 1]
            let following = section.dropFirst(end + 2).first { next.group == nil || $0.group != next.group }
            return try move(id, to: widget.position, before: following?.id, widgets: widgets)
        }
        return []
    }

    static func move(_ id: String, to position: WidgetPosition, before anchor: String? = nil,
                     widgets: [WidgetConfiguration]) throws -> [ConfigurationEdit] {
        guard let widget = widgets.first(where: { $0.id == id }) else {
            throw CommandFailure(message: "This widget is no longer available.")
        }
        let moving = widgets.filter { $0.id == id || (widget.group != nil && $0.group == widget.group) }
        let movingIDs = Set(moving.map(\.id))
        if let anchor, movingIDs.contains(anchor), moving.allSatisfy({ $0.position == position }) { return [] }
        var remaining = widgets.filter { !movingIDs.contains($0.id) }
        let insertion = insertionIndex(at: position, before: anchor, widgets: remaining)
        remaining.insert(contentsOf: moving, at: insertion)
        var edits = moving.filter { $0.position != position }.map {
            ConfigurationEdit(action: .set, id: $0.id, properties: ["position": .string(position.rawValue)])
        }
        let ids = remaining.map(\.id)
        if ids != widgets.map(\.id) { edits.append(ConfigurationEdit(action: .reorder, ids: ids)) }
        return edits
    }
}
