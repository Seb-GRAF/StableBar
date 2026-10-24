import Foundation

struct WidgetGroupConfiguration: Decodable, Sendable {
    var style: WidgetStyle

    enum CodingKeys: String, CodingKey, CaseIterable { case style }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        style = try values.decodeIfPresent(WidgetStyle.self, forKey: .style) ?? WidgetStyle()
    }
}

enum WidgetOverflow: String, Decodable, Sendable {
    case automatic, never
}

struct BarUnit: Identifiable {
    let id: String
    var widgets: [WidgetConfiguration]
    let style: WidgetStyle?

    var position: WidgetPosition { widgets[0].position }
    var priority: Int { widgets.map(\.priority).max()! }
    var canOverflow: Bool { widgets.allSatisfy { $0.overflow == .automatic } }
    var isSpacer: Bool { widgets.count == 1 && widgets[0].content == .spacer }

    /// How the unit enters and leaves the bar: the first transition its widgets set.
    var transition: WidgetTransition? { widgets.lazy.compactMap(\.transition).first }

    static func make(widgets: [WidgetConfiguration], groups: [String: WidgetGroupConfiguration]) -> [BarUnit] {
        var units: [BarUnit] = []
        for widget in widgets {
            if let group = widget.group {
                let id = "group:\(group)"
                if let index = units.firstIndex(where: { $0.id == id }) {
                    units[index].widgets.append(widget)
                } else {
                    units.append(BarUnit(id: id, widgets: [widget], style: groups[group]!.style))
                }
            } else {
                units.append(BarUnit(id: "widget:\(widget.id)", widgets: [widget], style: nil))
            }
        }
        return units
    }

    /// Whether a change of measured widths animates: the update tile's, and those of units that were
    /// already measured with the active app, expanding app menus or the Sound widget, whose volume
    /// comes and goes. `providerType` names the type of a widget's provider.
    static func animatesResize(_ units: [BarUnit], measured: Set<String>, from previous: [String: CGFloat],
                               to widths: [String: CGFloat], reduceMotion: Bool,
                               providerType: (WidgetConfiguration) -> String? = { _ in nil }) -> Bool {
        !reduceMotion && units.contains { unit in
            previous[unit.id] != widths[unit.id] && unit.widgets.contains {
                $0.id == AppUpdate.widgetID
                    || (($0.content == .activeApp || $0.content == .appMenu(expandOnHover: true) || $0.hoverLayout != nil || providerType($0) == DataSourceType.audio.name)
                        && measured.contains(unit.id))
            }
        }
    }
}

struct BarLayoutItem {
    let id: String
    let position: WidgetPosition
    let width: CGFloat
    var priority = 0
    var canOverflow = true
    var isSpacer = false
}

struct BarPlacement: Equatable {
    let x: CGFloat
    let width: CGFloat
}

struct BarOverflow: Equatable {
    let x: CGFloat
    let ids: [String]
}

struct AdaptiveBarPlan {
    var placements: [String: BarPlacement] = [:]
    var overflow: [BarOverflow] = []
}

struct AdaptiveBarPlanner {
    let inset: CGFloat
    let spacing: CGFloat
    let notchSpacing: CGFloat
    let notch: ClosedRange<CGFloat>?
    var overflowWidth: CGFloat = 30

    func plan(width: CGFloat, items: [BarLayoutItem]) -> AdaptiveBarPlan {
        var result = AdaptiveBarPlan()
        if let notch {
            let left: [WidgetPosition] = [.left, .notchLeft]
            let right: [WidgetPosition] = [.notchRight, .center, .right]
            segment(left.flatMap { position in items.filter { $0.position == position } },
                    start: inset, end: max(inset, notch.lowerBound - notchSpacing), buttonAtEnd: true, positions: left, result: &result)
            segment(right.flatMap { position in items.filter { $0.position == position } },
                    start: min(width - inset, notch.upperBound + notchSpacing), end: width - inset, buttonAtEnd: false,
                    positions: right, result: &result)
        } else {
            segment(items, start: inset, end: width - inset, buttonAtEnd: true,
                    positions: [.left, .notchLeft, .center, .notchRight, .right], result: &result)
        }
        return result
    }

    private func segment(_ items: [BarLayoutItem], start: CGFloat, end: CGFloat, buttonAtEnd: Bool,
                         positions: [WidgetPosition], result: inout AdaptiveBarPlan) {
        var visible = fitting(items, capacity: end - start, fromEnd: buttonAtEnd)
        if visible.count == items.count {
            place(visible, start: start, end: end, positions: positions, result: &result)
            return
        }
        let reserve = overflowWidth + spacing
        visible = fitting(visible, capacity: end - start - reserve, fromEnd: buttonAtEnd)
        let hidden = positions.flatMap { position in
            items.filter { item in item.position == position && !visible.contains { $0.id == item.id } }
        }
        result.overflow.append(BarOverflow(x: buttonAtEnd ? end - overflowWidth : start, ids: hidden.map(\.id)))
        place(visible, start: buttonAtEnd ? start : start + reserve, end: buttonAtEnd ? end - reserve : end,
              positions: positions, result: &result)
    }

    private func fitting(_ items: [BarLayoutItem], capacity: CGFloat, fromEnd: Bool) -> [BarLayoutItem] {
        var visible = items
        let candidates = items.enumerated().filter { $0.element.canOverflow && !$0.element.isSpacer }.sorted {
            if $0.element.priority != $1.element.priority { return $0.element.priority < $1.element.priority }
            return fromEnd ? $0.offset > $1.offset : $0.offset < $1.offset
        }
        for candidate in candidates {
            if occupiedWidth(visible) <= capacity { break }
            visible.removeAll { $0.id == candidate.element.id }
        }
        return visible
    }

    private func occupiedWidth(_ items: [BarLayoutItem]) -> CGFloat {
        items.reduce(0) { $0 + $1.width } + CGFloat(max(items.count - 1, 0)) * spacing
    }

    private func place(_ items: [BarLayoutItem], start: CGFloat, end: CGFloat,
                       positions: [WidgetPosition], result: inout AdaptiveBarPlan) {
        let capacity = max(end - start, 0)
        let ordered = positions.flatMap { position in items.filter { $0.position == position } }
        let gaps = min(spacing, capacity / CGFloat(max(ordered.count - 1, 1)))
        let contentWidth = ordered.reduce(CGFloat.zero) { $0 + $1.width }
        let availableWidth = max(capacity - CGFloat(max(ordered.count - 1, 0)) * gaps, 0)
        let scale = contentWidth > availableWidth ? availableWidth / contentWidth : 1
        let spacerCount = ordered.filter(\.isSpacer).count
        let extra = spacerCount == 0 ? 0 : max(availableWidth - contentWidth, 0) / CGFloat(spacerCount)
        let widths = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.width * scale + ($0.isSpacer ? extra : 0)) })
        let buckets = positions.map { position in ordered.filter { $0.position == position } }
        let sizes = buckets.map { bucket in bucket.reduce(CGFloat.zero) { $0 + widths[$1.id]! } + CGFloat(max(bucket.count - 1, 0)) * gaps }
        var origins = [CGFloat](repeating: start, count: buckets.count)
        if positions.count == 5 {
            origins = BarLayout(inset: 0, spacing: gaps, notchSpacing: 0, notch: nil)
                .origins(width: capacity, sizes: sizes).map { $0 + start }
            let middle = (1...3).filter { !buckets[$0].isEmpty }
            let middleWidth = middle.reduce(CGFloat.zero) { $0 + sizes[$1] } + CGFloat(max(middle.count - 1, 0)) * gaps
            let lower = start + sizes[0] + (buckets[0].isEmpty || middle.isEmpty ? 0 : gaps)
            let upper = end - sizes[4] - middleWidth - (buckets[4].isEmpty || middle.isEmpty ? 0 : gaps)
            if let first = middle.first {
                let x = min(max(origins[first], lower), max(lower, upper))
                let shift = x - origins[first]
                for index in middle { origins[index] += shift }
            }
        } else {
            var trailingX = end
            for index in buckets.indices.reversed() where index > 0 && !buckets[index].isEmpty {
                trailingX -= sizes[index]
                origins[index] = trailingX
                trailingX -= gaps
            }
        }
        for index in buckets.indices {
            var x = origins[index]
            for item in buckets[index] {
                let itemWidth = widths[item.id]!
                result.placements[item.id] = BarPlacement(x: x, width: itemWidth)
                x += itemWidth + gaps
            }
        }
    }
}
