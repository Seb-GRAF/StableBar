import SwiftUI

struct ControlEditingPreference: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct PopupSlider: View {
    let title: String
    let value: Double
    let minimum: Double
    let maximum: Double
    let step: Double
    let onChange: (Double) -> Void
    @State private var localValue: Double?
    @State private var editing = false
    @State private var labelWidth = 0.0

    private var shown: Double { localValue ?? min(max(value, minimum), maximum) }

    var body: some View {
        SteppedSlider(value: Binding(get: { shown }, set: { localValue = $0 }),
                      in: minimum...maximum, step: step) {
            Text(title).onGeometryChange(for: Double.self) { $0.size.width } action: { labelWidth = $0 }
        } onEditingChanged: { editing in
            self.editing = editing
            if !editing, let localValue { onChange(localValue) }
        }
        .accessibilityLabel(title)
        .modifier(FocusRing { [labelWidth, shown] in
            // Around the knob, which macOS draws 20 by 16 points on a track that starts where the label ends.
            GeometryReader { proxy in
                FocusRingShape(shape: Capsule())
                    .frame(width: 20, height: 16)
                    .position(x: labelWidth + 10 + (shown - minimum) / (maximum - minimum) * (proxy.size.width - labelWidth - 20),
                              y: proxy.size.height / 2)
            }
        })
        .onChange(of: value) { if !editing { localValue = nil } }
        .preference(key: ControlEditingPreference.self, value: editing)
    }
}

struct PopupToggle: View {
    let title: String
    let value: Bool
    let onChange: (Bool) -> Void
    @State private var localValue: Bool?

    var body: some View {
        Toggle(title, isOn: Binding(get: { localValue ?? value }, set: {
            localValue = $0
            onChange($0)
        }))
        .modifier(FocusRing {
            // The checkbox is a square as tall as the toggle at its leading edge.
            FocusRingShape(shape: RoundedRectangle(cornerRadius: 8)).aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity, alignment: .leading)
        })
        .onChange(of: value) { localValue = nil }
    }
}

struct PopupInput: View {
    let title: String
    let placeholder: String?
    let autofocus: Bool
    let wraps: Bool
    let sendButton: Bool
    /// Whether the send button stops instead of sending.
    let busy: Bool
    let onSubmit: (String) -> Void
    let onStop: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if sendButton {
            // The block's style draws the field's shape, as an AI app's message field.
            HStack(alignment: .bottom, spacing: 8) {
                field.textFieldStyle(.plain).frame(minHeight: 28)
                let empty = !busy && text.isEmpty
                Button { busy ? onStop() : submit() } label: {
                    Image(systemName: busy ? "stop.fill" : "arrow.up")
                        .font(.system(size: busy ? 10 : 13, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(.background)
                        .frame(width: 28, height: 28)
                        .background(.foreground.opacity(empty ? 0.3 : 1), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(empty)
                .help(busy ? "Stop" : "Send")
                .accessibilityLabel(busy ? "Stop" : "Send")
            }
        } else {
            field.textFieldStyle(.roundedBorder)
        }
    }

    private var field: some View {
        TextField(title, text: $text, prompt: placeholder.map { Text($0) }, axis: wraps ? .vertical : .horizontal)
            .lineLimit(6)
            .accessibilityLabel(title)
            .focused($focused)
            .onAppear { focused = autofocus }
            .onSubmit(submit)
            // Return sends; Shift-Return starts a new line, as Option-Return already does in a field that wraps.
            .onKeyPress(.return, phases: .down) { press in
                guard wraps, press.modifiers.contains(.shift) else { return .ignored }
                NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                return .handled
            }
    }

    private func submit() {
        onSubmit(text)
        text = ""
    }
}

/// A pill naming the chosen group, option and level, or chips for the starred presets with the chosen one highlighted,
/// that opens a panel to change them: the groups, and the starred presets, on the left, and on the right the chosen
/// group's options and a bar of its levels. Choices show at once and run `onChange` with all three.
struct PopupChooser: View {
    let title: String
    let chosen: String
    let groups: [[String: String]]
    let options: [[String: String]]
    let levels: [[String: String]]
    /// Starred presets: rows with `group`, `option` and `level`, in the order of their ⌘1 to ⌘9 shortcuts; nil when
    /// options can't be starred.
    let stars: [[String: String]]?
    let onChange: (_ group: String, _ option: String, _ level: String) -> Void
    let onStar: (_ group: String, _ option: String, _ level: String, _ starred: Bool) -> Void
    @State private var group: String?
    @State private var chosenOptions: [String: String] = [:]
    @State private var chosenLevels: [String: String] = [:]
    @State private var starred: [[String: String]]?
    @State private var showsPanel = false
    @State private var showsStars = false
    @State private var panelClosed = Date.distantPast
    @Namespace private var highlight
    @Namespace private var chipHighlight

    private var current: String { group ?? chosen }
    private var presets: [[String: String]] { starred ?? stars ?? [] }
    private func row(_ group: String) -> [String: String] { groups.first { $0["value"] == group } ?? [:] }
    private func options(of group: String) -> [[String: String]] { options.filter { $0["group"] == group } }
    private func levels(of group: String) -> [[String: String]] { levels.filter { $0["group"] == group } }
    private func option(of group: String) -> String { chosenOptions[group] ?? row(group)["option"] ?? options(of: group).first?["value"] ?? "" }
    private func level(of group: String) -> String { chosenLevels[group] ?? row(group)["level"] ?? levels(of: group).first?["value"] ?? "" }
    private func title(_ value: String, in rows: [[String: String]]) -> String { rows.first { $0["value"] == value }?["title"] ?? value }
    private func isChosen(_ preset: [String: String]) -> Bool {
        preset["group"] == current && preset["option"] == option(of: current) && preset["level"] == level(of: current)
    }

    private func choose(_ group: String) {
        self.group = group
        onChange(group, option(of: group), level(of: group))
    }

    private func choose(_ preset: [String: String]) {
        let group = preset["group"] ?? ""
        chosenOptions[group] = preset["option"]
        chosenLevels[group] = preset["level"]
        choose(group)
    }

    private func toggleStar(_ group: String, _ option: String) {
        var presets = presets
        if let index = presets.firstIndex(where: { $0["group"] == group && $0["option"] == option }) {
            let removed = presets.remove(at: index)
            starred = presets
            onStar(group, option, removed["level"] ?? "", false)
        } else {
            presets.append(["group": group, "option": option, "level": level(of: group)])
            starred = presets
            onStar(group, option, level(of: group), true)
        }
    }

    private func togglePanel() {
        // A click on the label while the panel shows closes the panel as the mouse goes down, before the click's action.
        guard showsPanel || Date.now.timeIntervalSince(panelClosed) > 0.3 else { return }
        showsPanel.toggle()
    }

    var body: some View {
        Group {
            if presets.isEmpty {
                Button(action: togglePanel) {
                    HStack(spacing: 6) {
                        if let icon = row(current)["icon"] { Image(systemName: icon).contentTransition(.symbolEffect(.replace)) }
                        (Text(row(current)["title"] ?? current).fontWeight(.semibold)
                            + Text("  ·  \(title(option(of: current), in: options(of: current)))"
                                   + (levels(of: current).isEmpty ? "" : "  ·  \(title(level(of: current), in: levels(of: current)))"))
                            .foregroundStyle(.secondary))
                            .lineLimit(1)
                            .contentTransition(.interpolate)
                        chevron
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(FocusRing { FocusRingShape(shape: Capsule()).padding(.horizontal, -3) })
            } else {
                HStack(spacing: 2) {
                    ChipRow(spacing: 2) {
                        ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                            chip(preset["group"] ?? "", option: preset["option"] ?? "", level: preset["level"] ?? "", active: isChosen(preset)) {
                                if isChosen(preset) { togglePanel() } else { choose(preset) }
                            }
                            .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command) : nil)
                        }
                    }
                    .clipped()
                    if !presets.contains(where: isChosen) {
                        chip(current, option: option(of: current), level: level(of: current), active: true, action: togglePanel)
                    }
                    Button(action: togglePanel) { chevron.padding(6).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .modifier(FocusRing { FocusRingShape(shape: Capsule(), outset: 0) })
                }
            }
        }
        .accessibilityLabel(title)
        .animation(.snappy(duration: 0.3), value: [current, option(of: current), level(of: current)])
        .animation(.snappy(duration: 0.25), value: showsPanel)
        // The label's width changes with the choice; the panel stays put under a fixed stretch of it.
        .overlay(alignment: .leading) {
            Color.clear.frame(width: 200).allowsHitTesting(false).popover(isPresented: $showsPanel, arrowEdge: .bottom) { panel }
        }
        .onChange(of: showsPanel) { if !showsPanel { panelClosed = .now } }
        .onChange(of: chosen) { group = nil }
        .onChange(of: groups) {
            chosenOptions = [:]
            chosenLevels = [:]
        }
        .onChange(of: stars) { starred = nil }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .rotationEffect(.degrees(showsPanel ? 180 : 0))
    }

    private func chip(_ group: String, option: String, level: String, active: Bool, action: @escaping () -> Void) -> some View {
        ChooserChip(active: active, highlight: chipHighlight, action: action) {
            HStack(spacing: 5) {
                Text(title(option, in: options(of: group))).fontWeight(active ? .semibold : .regular)
                if !levels(of: group).isEmpty { Text(title(level, in: levels(of: group))).foregroundStyle(.secondary) }
            }
        }
    }

    private var panel: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if !presets.isEmpty {
                    ChooserRow(selected: showsStars, highlight: highlight) {
                        HStack(spacing: 9) {
                            Image(systemName: "star").frame(width: 18)
                            Text("Starred")
                            Spacer(minLength: 0)
                        }
                    } choose: {
                        showsStars = true
                    }
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { _, row in
                    let value = row["value"] ?? ""
                    ChooserRow(selected: !showsStars && value == current, highlight: highlight) {
                        HStack(spacing: 9) {
                            if let icon = row["icon"] { Image(systemName: icon).frame(width: 18) }
                            Text(row["title"] ?? value)
                            Spacer(minLength: 0)
                        }
                    } choose: {
                        showsStars = false
                        choose(value)
                    }
                }
            }
            .padding(8)
            .frame(width: 168, alignment: .topLeading)
            Divider()
            Group {
                if showsStars { starredPresets } else { details(current) }
            }
            .id(showsStars ? "" : current)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 14)), removal: .opacity))
            .frame(width: 300, alignment: .topLeading)
        }
        // A fixed size keeps the panel still as groups with more or fewer options take turns in it.
        .frame(height: 420, alignment: .top)
        .animation(.snappy(duration: 0.32), value: current)
        .animation(.snappy(duration: 0.32), value: showsStars)
        .onAppear { showsStars = false }
    }

    private var starredPresets: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                    let group = preset["group"] ?? "", option = preset["option"] ?? "", level = preset["level"] ?? ""
                    ChooserRow(selected: false, highlight: highlight) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text([title(option, in: options(of: group)), title(level, in: levels(of: group))].joined(separator: " · "))
                                Text(row(group)["title"] ?? group).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if index < 9 { Text("⌘\(index + 1)").font(.caption).foregroundStyle(.tertiary) }
                            starButton(group, option)
                            checkmark(isChosen(preset))
                        }
                    } choose: {
                        choose(preset)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func details(_ group: String) -> some View {
        let row = row(group)
        let levels = levels(of: group)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let icon = row["icon"] {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .frame(width: 32, height: 32)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row["title"] ?? group).font(.headline)
                    if let detail = row["detail"] { Text(detail).font(.callout).foregroundStyle(.secondary) }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(options(of: group).enumerated()), id: \.offset) { _, option in
                        let value = option["value"] ?? ""
                        ChooserRow(selected: false, highlight: highlight) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option["title"] ?? value)
                                    if let detail = option["detail"] { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                }
                                Spacer(minLength: 0)
                                if stars != nil { starButton(group, value) }
                                checkmark(value == self.option(of: group))
                            }
                        } choose: {
                            chosenOptions[group] = value
                            choose(group)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            if !levels.isEmpty {
                let level = self.level(of: group)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(row["levelsTitle"] ?? "Level").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(title(level, in: levels)).font(.caption.weight(.semibold)).foregroundStyle(.tint).contentTransition(.interpolate)
                    }
                    LevelBar(title: row["levelsTitle"] ?? "Level", levels: levels, chosen: level) {
                        chosenLevels[group] = $0
                        choose(group)
                    }
                }
                .animation(.snappy(duration: 0.25), value: level)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func starButton(_ group: String, _ option: String) -> some View {
        let starred = presets.contains { $0["group"] == group && $0["option"] == option }
        return Button { toggleStar(group, option) } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .foregroundStyle(starred ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(starred ? "Unstar" : "Star with its \((row(group)["levelsTitle"] ?? "level").lowercased())")
    }

    private func checkmark(_ chosen: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.tint)
            .scaleEffect(chosen ? 1 : 0.4)
            .opacity(chosen ? 1 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: chosen)
    }
}

/// Chips side by side, as many as fit whole. The rest wait past the trailing edge, where clipping hides them and their
/// keyboard shortcuts still work.
private struct ChipRow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let shown = shownCount(sizes, width: proposal.width ?? .infinity)
        let width = sizes.prefix(shown).reduce(0) { $0 + $1.width } + spacing * CGFloat(max(shown - 1, 0))
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let shown = shownCount(sizes, width: bounds.width)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: index < shown ? x : bounds.maxX + 1000, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            x += sizes[index].width + spacing
        }
    }

    private func shownCount(_ sizes: [CGSize], width: CGFloat) -> Int {
        var used = -spacing
        return sizes.prefix { size in
            used += spacing + size.width
            return used <= width + 0.5
        }.count
    }
}

/// A starred preset in the chooser's label, its highlight sliding to the chosen one.
private struct ChooserChip<Label: View>: View {
    let active: Bool
    let highlight: Namespace.ID
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    if active {
                        Capsule().fill(.quaternary).matchedGeometryEffect(id: "chip", in: highlight)
                    } else if hovered {
                        Capsule().fill(.quinary)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(FocusRing { FocusRingShape(shape: Capsule(), outset: 0) })
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// A row in the chooser's panel that highlights on hover, and when `selected`, with a highlight that slides between rows.
private struct ChooserRow<Label: View>: View {
    let selected: Bool
    let highlight: Namespace.ID
    @ViewBuilder let label: Label
    let choose: () -> Void
    @State private var hovered = false

    var body: some View {
        label
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary).matchedGeometryEffect(id: "selection", in: highlight)
                } else if hovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quinary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: choose)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Levels side by side in a bar that fills up to the chosen one. Click or drag along it to choose; the pointer previews
/// the level under it.
private struct LevelBar: View {
    let title: String
    let levels: [[String: String]]
    let chosen: String
    let choose: (String) -> Void
    @State private var dragged: Int?
    @State private var hovered: Int?

    var body: some View {
        let index = dragged ?? levels.firstIndex { $0["value"] == chosen } ?? 0
        GeometryReader { proxy in
            let segment = proxy.size.width / CGFloat(levels.count)
            let position = { (x: CGFloat) in min(max(Int(x / segment), 0), levels.count - 1) }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary)
                if let hovered, hovered > index {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.tint.opacity(0.22)).frame(width: segment * CGFloat(hovered + 1))
                }
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.tint).frame(width: segment * CGFloat(index + 1))
                ForEach(1..<levels.count, id: \.self) { tick in
                    Capsule()
                        .fill(tick <= index ? Color.white.opacity(0.45) : Color.primary.opacity(0.18))
                        .frame(width: 2, height: 8)
                        .offset(x: segment * CGFloat(tick) - 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragged = position($0.location.x) }
                .onEnded {
                    choose(levels[position($0.location.x)]["value"] ?? "")
                    dragged = nil
                })
            .onContinuousHover { phase in
                if case let .active(point) = phase { hovered = position(point.x) } else { hovered = nil }
            }
        }
        .frame(height: 22)
        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: index)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(levels[index]["title"] ?? "")
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? min(index + 1, levels.count - 1) : max(index - 1, 0)
            choose(levels[next]["value"] ?? "")
        }
    }
}

struct PopupSegmented: View {
    let title: String
    let value: String
    let options: [PopupControlOption]
    let onChange: (String) -> Void
    @State private var localValue: String?

    var body: some View {
        LabeledContent {
            Picker(title, selection: Binding(get: { localValue ?? value }, set: {
                localValue = $0
                onChange($0)
            })) {
                ForEach(options, id: \.value) { option in Text(option.title).tag(option.value) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(title)
            .modifier(FocusRing { FocusRingShape(shape: RoundedRectangle(cornerRadius: 11)) })
        } label: {
            Text(title).accessibilityHidden(true)
        }
        .onChange(of: value) { localValue = nil }
    }
}

struct PopupMenuRow: View {
    let item: WidgetMenuItem
    let appearance: WidgetAppearance
    let runAction: (String) -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let command = item.onClick {
                Button { runAction(command) } label: { label }
                    .buttonStyle(.plain)
                    .focused($focused)
            } else {
                label
            }
        }
        .background(hovered && item.onClick != nil ? appearance.hoverBackground : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: appearance.cornerRadius))
        .overlay { if focused { FocusRingShape(shape: RoundedRectangle(cornerRadius: appearance.cornerRadius), outset: 0) } }
        .onHover { hovered = $0 }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(item.onClick == nil ? appearance.font.weight(.semibold) : appearance.font)
            if let detail = item.detail {
                Text(detail).foregroundStyle(appearance.foreground.opacity(0.7))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .contentShape(Rectangle())
    }
}
