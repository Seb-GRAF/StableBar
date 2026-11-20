import Foundation

struct WidgetGroupConfiguration: Decodable, Sendable {
    var style: WidgetStyle
    let members: [WidgetGroupMember]

    enum CodingKeys: String, CodingKey, CaseIterable { case style, members }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        style = try values.decodeIfPresent(WidgetStyle.self, forKey: .style) ?? WidgetStyle()
        members = try values.decodeIfPresent([WidgetGroupMember].self, forKey: .members) ?? []
    }

    var takesOthers: Bool { members.contains(where: \.others) }

    /// `widgets`, each enabled one without a `group` in the group whose `members` match it best, unless that group's
    /// widgets sit in another position and it doesn't take others. Widgets with their own `group` settle a group's
    /// position first. `ownGroup` can stand in for a widget's own `group`, to see where a widget would go without it.
    static func joining(_ widgets: [WidgetConfiguration], groups: [String: WidgetGroupConfiguration],
                        ownGroup: (WidgetConfiguration) -> String? = \.ownGroup) -> [WidgetConfiguration] {
        var positions: [String: WidgetPosition] = [:]
        for widget in widgets {
            if let group = ownGroup(widget), positions[group] == nil { positions[group] = widget.position }
        }
        var joined = widgets
        for index in joined.indices {
            joined[index].joinedGroup = nil
            let widget = joined[index]
            guard ownGroup(widget) == nil, widget.enabled else { continue }
            let matches = groups.sorted { $0.key < $1.key }.flatMap { id, group in
                group.members.filter { $0.matches(widget) }.map { (group: id, rank: ($0.others ? -1 : $0.id == nil ? 0 : 1, $0.keyCount)) }
            }
            guard let best = matches.first(where: { match in !matches.contains { $0.rank > match.rank } }),
                  groups[best.group]!.takesOthers || (positions[best.group] ?? widget.position) == widget.position else { continue }
            positions[best.group] = widget.position
            joined[index].joinedGroup = best.group
        }
        return joined
    }
}

/// A selector in a group's `members`: a widget matches when it has every key the selector names.
struct WidgetGroupMember: Decodable, Equatable, Sendable {
    let type: String?
    let role: PresentationRole?
    let id: String?
    /// Takes the widgets other than spacers that no other selector names, by ranking below every selector that names one.
    var others = false

    enum CodingKeys: String, CodingKey, CaseIterable { case type, role, id, others }

    init(type: String?, role: PresentationRole?, id: String?) {
        self.type = type
        self.role = role
        self.id = id
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decodeIfPresent(String.self, forKey: .type).map { name in
            guard let type = WidgetConfiguration.typeName(name) else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown widget type.")
            }
            return type
        }
        role = try values.decodeIfPresent(PresentationRole.self, forKey: .role)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        others = try values.decodeIfPresent(Bool.self, forKey: .others) ?? false
        guard keyCount > 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Name a type, role or id, or set others to true."))
        }
    }

    var keyCount: Int { [type != nil, role != nil, id != nil, others].filter { $0 }.count }

    func matches(_ widget: WidgetConfiguration) -> Bool {
        (type == nil || type == widget.typeName) && (role == nil || role == widget.role) && (id == nil || id == widget.id)
            && !(others && widget.content == .spacer)
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
    /// Whether the unit has App menus that hide their last menus behind » to fit.
    var hasShrinkingAppMenus: Bool {
        widgets.contains {
            guard case .appMenu(expandOnHover: false, displayMode: _) = $0.content else { return false }
            return $0.layout == nil
        }
    }

    /// How the unit enters and leaves the bar: the first transition its widgets set.
    var transition: WidgetTransition? { widgets.lazy.compactMap(\.transition).first }

    static func make(widgets: [WidgetConfiguration], groups: [String: WidgetGroupConfiguration]) -> [BarUnit] {
        var units: [BarUnit] = []
        for widget in widgets {
            if let group = widget.group {
                let id = groups[group]!.takesOthers ? "group-\(widget.position.rawValue):\(group)" : "group:\(group)"
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
                    || (($0.content == .activeApp || isExpandingAppMenu($0.content) || $0.hoverLayout != nil || providerType($0) == DataSourceType.audio.name)
                        && measured.contains(unit.id))
            }
        }
    }
}

private func isExpandingAppMenu(_ content: WidgetContent) -> Bool {
    if case .appMenu(expandOnHover: true, displayMode: _) = content { return true }
    return false
}

struct BarLayoutItem {
    let id: String
    let position: WidgetPosition
    var width: CGFloat
    var priority = 0
    var canOverflow = true
    var isSpacer = false
    var growth: CGFloat = 0
    var minimumWidth: CGFloat?
}

struct BarPlacement: Equatable {
    let x: CGFloat
    let width: CGFloat
}

struct BarOverflow: Equatable {
    let x: CGFloat
    let atEnd: Bool
    let ids: [String]
}

/// The part of the bar on one side of the notch, or all of it without one. With `scrolls`, the items that don't fit
/// run `overflow` points past its `span`; they would go to More widgets on that side's `atEnd`.
struct BarSegment: Equatable {
    let positions: [WidgetPosition]
    let span: ClosedRange<CGFloat>
    let atEnd: Bool
    var overflow: CGFloat = 0
}

struct AdaptiveBarPlan {
    var placements: [String: BarPlacement] = [:]
    var overflow: [BarOverflow] = []
    var cramped: Set<String> = []
    var segments: [BarSegment] = []
    /// The middle of the gap after each placed item that another one follows side by side, by the first one's ID.
    var dividers: [String: CGFloat] = [:]
}

struct AdaptiveBarPlanner {
    let inset: CGFloat
    let spacing: CGFloat
    let notchSpacing: CGFloat
    let notch: ClosedRange<CGFloat>?
    var overflowWidth: CGFloat = 30
    /// Items that don't fit run past their segment at full width, to scroll, instead of shrinking.
    var scrolls = false
    /// Room between positions beyond `spacing`.
    var positionSpacing: CGFloat = 0

    func plan(width: CGFloat, items: [BarLayoutItem]) -> AdaptiveBarPlan {
        var result = AdaptiveBarPlan()
        if let notch {
            let left: [WidgetPosition] = [.left, .notchLeft]
            let right: [WidgetPosition] = [.notchRight, .center, .right]
            segment(left.flatMap { position in items.filter { $0.position == position } },
                    start: inset, end: max(inset, notch.lowerBound - notchSpacing), buttonAtEnd: true, atNotch: .notchLeft,
                    positions: left, result: &result)
            segment(right.flatMap { position in items.filter { $0.position == position } },
                    start: min(width - inset, notch.upperBound + notchSpacing), end: width - inset, buttonAtEnd: false, atNotch: .notchRight,
                    positions: right, result: &result)
        } else {
            segment(items, start: inset, end: width - inset, buttonAtEnd: true, atNotch: nil,
                    positions: [.left, .notchLeft, .center, .notchRight, .right], result: &result)
        }
        // The positions the bar draws side by side: beside a notch, `center` runs into `right`.
        let runs: [[WidgetPosition]] = notch == nil ? [[.left], [.notchLeft, .center, .notchRight], [.right]]
            : [[.left], [.notchLeft], [.notchRight], [.center, .right]]
        for run in runs {
            let placed = run.flatMap { position in items.filter { $0.position == position && result.placements[$0.id] != nil } }
            for (item, next) in zip(placed, placed.dropFirst()) where !item.isSpacer && !next.isSpacer {
                let placement = result.placements[item.id]!
                result.dividers[item.id] = (placement.x + placement.width + result.placements[next.id]!.x) / 2
            }
        }
        return result
    }

    private func segment(_ items: [BarLayoutItem], start: CGFloat, end: CGFloat, buttonAtEnd: Bool, atNotch: WidgetPosition?,
                         positions: [WidgetPosition], result: inout AdaptiveBarPlan) {
        var visible = fitting(items, capacity: end - start, fromEnd: buttonAtEnd)
        let overflows = visible.count < items.count
        let reserve = overflows ? overflowWidth + spacing : 0
        if overflows {
            // Refit at full widths: the items the reserve moves out leave room the first pass's shrinking didn't have.
            visible = fitting(items.filter { item in visible.contains { $0.id == item.id } },
                              capacity: end - start - reserve, fromEnd: buttonAtEnd)
        }
        var room = end - start - reserve - occupiedWidth(visible)
        for index in visible.indices where visible[index].growth > 0 {
            if visible[index].growth <= room {
                visible[index].width += visible[index].growth
                room -= visible[index].growth
            } else {
                result.cramped.insert(visible[index].id)
            }
        }
        place(visible, start: buttonAtEnd ? start : start + reserve, end: buttonAtEnd ? end - reserve : end,
              positions: positions, atEnd: buttonAtEnd, result: &result)
        guard overflows else { return }
        let hidden = positions.flatMap { position in
            items.filter { item in item.position == position && !visible.contains { $0.id == item.id } }
        }
        let held = visible.filter { $0.position == atNotch }.map(\.id)
        for id in held {
            let placement = result.placements[id]!
            result.placements[id] = BarPlacement(x: placement.x + (buttonAtEnd ? reserve : -reserve), width: placement.width)
        }
        let x: CGFloat
        if held.isEmpty {
            let placed = visible.map { result.placements[$0.id]! }
            x = buttonAtEnd
                ? placed.map { $0.x + $0.width + spacing }.max() ?? end - overflowWidth
                : placed.map { $0.x - spacing - overflowWidth }.min() ?? start
        } else {
            let placed = held.map { result.placements[$0]! }
            x = buttonAtEnd ? placed.map(\.x).min()! - spacing - overflowWidth : placed.map { $0.x + $0.width }.max()! + spacing
        }
        result.overflow.append(BarOverflow(x: x, atEnd: buttonAtEnd, ids: hidden.map(\.id)))
    }

    /// The items that fit in `capacity`, lowest priority first, then latest in the configuration, moving to More
    /// widgets. An item that can shrink, such as the app menus, counts at its minimum width and goes after the others
    /// of its priority, then takes the room left, up to its full width.
    private func fitting(_ items: [BarLayoutItem], capacity: CGFloat, fromEnd: Bool) -> [BarLayoutItem] {
        var visible = items
        let candidates = items.enumerated().filter { $0.element.canOverflow && !$0.element.isSpacer }.sorted {
            if $0.element.priority != $1.element.priority { return $0.element.priority < $1.element.priority }
            if ($0.element.minimumWidth == nil) != ($1.element.minimumWidth == nil) { return $1.element.minimumWidth != nil }
            return fromEnd ? $0.offset > $1.offset : $0.offset < $1.offset
        }
        for candidate in candidates {
            if smallestWidth(visible) <= capacity { break }
            visible.removeAll { $0.id == candidate.element.id }
        }
        var excess = occupiedWidth(visible) - capacity
        for index in visible.indices.reversed() where excess > 0 {
            guard let minimum = visible[index].minimumWidth else { continue }
            let cut = min(excess, max(visible[index].width - minimum, 0))
            visible[index].width -= cut
            excess -= cut
        }
        return visible
    }

    private func smallestWidth(_ items: [BarLayoutItem]) -> CGFloat {
        items.reduce(0) { $0 + min($1.minimumWidth ?? $1.width, $1.width) } + CGFloat(max(items.count - 1, 0)) * spacing
    }

    private func occupiedWidth(_ items: [BarLayoutItem]) -> CGFloat {
        items.reduce(0) { $0 + $1.width } + CGFloat(max(items.count - 1, 0)) * spacing
    }

    private func place(_ items: [BarLayoutItem], start: CGFloat, end: CGFloat,
                       positions: [WidgetPosition], atEnd: Bool, result: inout AdaptiveBarPlan) {
        let capacity = max(end - start, 0)
        let ordered = positions.flatMap { position in items.filter { $0.position == position } }
        let gaps = scrolls ? spacing : min(spacing, capacity / CGFloat(max(ordered.count - 1, 1)))
        let between = gaps + positionSpacing
        let buckets = positions.map { position in ordered.filter { $0.position == position } }
        let filled = buckets.filter { !$0.isEmpty }.count
        let contentWidth = ordered.reduce(CGFloat.zero) { $0 + $1.width }
        let gapWidth = CGFloat(max(ordered.count - 1, 0)) * gaps + CGFloat(max(filled - 1, 0)) * positionSpacing
        let availableWidth = max(capacity - gapWidth, 0)
        let overflow = scrolls ? max(contentWidth + gapWidth - capacity, 0) : 0
        result.segments.append(BarSegment(positions: positions, span: start...max(start, end), atEnd: atEnd, overflow: overflow))
        let scale = overflow == 0 && contentWidth > availableWidth ? availableWidth / contentWidth : 1
        let spacerCount = ordered.filter(\.isSpacer).count
        let extra = spacerCount == 0 ? 0 : max(availableWidth - contentWidth, 0) / CGFloat(spacerCount)
        let widths = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.width * scale + ($0.isSpacer ? extra : 0)) })
        let sizes = buckets.map { bucket in bucket.reduce(CGFloat.zero) { $0 + widths[$1.id]! } + CGFloat(max(bucket.count - 1, 0)) * gaps }
        var origins = [CGFloat](repeating: start, count: buckets.count)
        if positions.count == 5 {
            origins = BarLayout(inset: 0, spacing: between, notchSpacing: 0, notch: nil)
                .origins(width: capacity, sizes: sizes).map { $0 + start }
            let middle = (1...3).filter { !buckets[$0].isEmpty }
            let middleWidth = middle.reduce(CGFloat.zero) { $0 + sizes[$1] } + CGFloat(max(middle.count - 1, 0)) * between
            let lower = start + sizes[0] + (buckets[0].isEmpty || middle.isEmpty ? 0 : between)
            let upper = end - sizes[4] - middleWidth - (buckets[4].isEmpty || middle.isEmpty ? 0 : between)
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
                trailingX -= between
            }
        }
        if overflow > 0 {
            var x = start
            for index in buckets.indices where !buckets[index].isEmpty {
                origins[index] = x
                x += sizes[index] + between
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
