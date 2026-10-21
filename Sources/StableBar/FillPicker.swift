import AppKit
import SwiftUI

struct ThemeTokenColor: Identifiable {
    let name: String
    let title: String
    let color: HexColor
    var id: String { name }
}

extension BarStore {
    var themeTokenColors: [ThemeTokenColor] { themeTokenColors(in: effectiveDocument) }

    func themeTokenColors(in document: [String: ConfigurationValue]) -> [ThemeTokenColor] {
        let tokens = (try? document["tokens"]?.decoded([String: ConfigurationValue].self)) ?? [:]
        return themeTokens.compactMap { token in
            (try? tokens[token.name]?.decoded(HexColor.self)).map { ThemeTokenColor(name: token.name, title: token.title, color: $0) }
        }
    }
}

struct FillButton: View {
    let title: String
    let value: ConfigurationValue?
    let tokens: [ThemeTokenColor]
    var allowsGradient = false
    var allowsNone = false
    var arrowEdge: Edge = .leading
    let set: (ConfigurationValue) -> Void
    @State private var isPresented = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let fill = FillChoice(value)
        let label = label(fill)
        Button { isPresented.toggle() } label: {
            HStack(spacing: 7) {
                FillChip(fill: fill, tokens: tokens)
                label.lineLimit(1)
            }
            .font(.callout)
            .padding(.leading, 4)
            .padding(.trailing, 24)
            .frame(width: 200, height: 28, alignment: .leading)
            .overlay(alignment: .trailing) {
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7)).foregroundStyle(.tertiary).padding(.trailing, 9)
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(isHovered ? 0.11 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(label)
        .popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
            FillPopover(title: title, value: value, tokens: tokens, allowsGradient: allowsGradient, allowsNone: allowsNone,
                        themeColor: false, dark: colorScheme == .dark, set: set)
        }
    }

    private func label(_ fill: FillChoice) -> Text {
        let detail = { (text: String) in Text(" \(text)").font(.system(size: 10)).foregroundStyle(.tertiary) }
        switch fill {
        case .none:
            return Text("None")
        case let .token(name):
            return Text(tokens.first { $0.name == name }?.title ?? name) + detail("theme")
        case let .color(color):
            let text = Text(String(format: "#%06X", color.rgba(dark: colorScheme == .dark) >> 8))
            return color.light == color.dark ? text : text + detail("light/dark")
        case let .gradient(gradient):
            return Text("Gradient") + detail("\(gradient.angle)°")
        }
    }
}

struct TokenColorButton: View {
    let title: String
    let color: HexColor
    let dark: Bool
    let property: PropertySources
    let reset: (() -> Void)?
    let set: (ConfigurationValue) -> Void
    @State private var isPresented = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shown = color.rgba(dark: dark)
        let hex = String(format: "#%06X", shown >> 8)
        Button { isPresented.toggle() } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(hex).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                FillChip(fill: .color(color), tokens: [], width: 36, height: 36, cornerRadius: 8)
                    .padding(.leading, 32)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 9).fill(colorScheme == .dark ? Color.white.opacity(0.05) : .white))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(isHovered ? 0.3 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            RevertSettingButton(title: title, property: property, reset: reset)
                .padding(.trailing, 56)
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(hex)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            FillPopover(title: title, value: color.configurationValue, tokens: [], allowsGradient: false, allowsNone: false,
                        themeColor: true, dark: dark, set: set)
        }
    }
}

private enum FillChoice: Equatable {
    case none
    case token(String)
    case color(HexColor)
    case gradient(GradientChoice)

    init(_ value: ConfigurationValue?) {
        if case let .string(text) = value, text.hasPrefix("@token.") {
            self = .token(String(text.dropFirst(7)))
        } else if let color = try? value?.decoded(HexColor.self) {
            self = .color(color)
        } else if let gradient = try? value?.decoded([String: GradientChoice].self)["gradient"] {
            self = .gradient(gradient)
        } else {
            self = .none
        }
    }

    var configurationValue: ConfigurationValue {
        switch self {
        case .none: .null
        case let .token(name): .string("@token.\(name)")
        case let .color(color): color.configurationValue
        case let .gradient(gradient): .object(["gradient": gradient.configurationValue])
        }
    }

    func rgba(dark: Bool, tokens: [ThemeTokenColor]) -> UInt32 {
        switch self {
        case .none: 0x808080ff
        case let .token(name): (tokens.first { $0.name == name }?.color ?? HexColor(0)).rgba(dark: dark)
        case let .color(color): color.rgba(dark: dark)
        case let .gradient(gradient): gradient.stops[0].color.rgba(dark: dark, tokens: tokens)
        }
    }

    var hasDarkVariant: Bool {
        if case let .color(color) = self { color.light != color.dark } else { false }
    }
}

private struct GradientChoice: Equatable, Decodable {
    struct Stop: Equatable {
        var color: FillChoice
        var location: Double
    }

    var stops: [Stop]
    var angle: Int

    enum CodingKeys: String, CodingKey { case colors, angle, locations }

    init(colors: [FillChoice], locations: [Double]? = nil, angle: Int) {
        let locations = locations ?? colors.indices.map { Double($0) / Double(colors.count - 1) }
        stops = zip(colors, locations).map { Stop(color: $0, location: $1) }
        self.angle = angle
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(colors: try values.decode([ConfigurationValue].self, forKey: .colors).map(FillChoice.init),
                  locations: try values.decodeIfPresent([Double].self, forKey: .locations),
                  angle: (Int(try values.decodeIfPresent(Double.self, forKey: .angle) ?? 90) % 360 + 360) % 360)
    }

    var configurationValue: ConfigurationValue {
        let stops = stops.sorted { $0.location < $1.location }
        var gradient: [String: ConfigurationValue] = ["colors": .array(stops.map(\.color.configurationValue)), "angle": .number(Double(angle))]
        if stops.indices.contains(where: { abs(stops[$0].location - Double($0) / Double(stops.count - 1)) >= 0.01 }) {
            gradient["locations"] = .array(stops.map { .number($0.location) })
        }
        return .object(gradient)
    }
}

private extension HexColor {
    func rgba(dark: Bool) -> UInt32 { dark ? self.dark : light }
}

private enum FillMode: String {
    case theme = "Theme", color = "Color", gradient = "Gradient", none = "None"
}

private struct FillPopover: View {
    let title: String
    let value: ConfigurationValue?
    let tokens: [ThemeTokenColor]
    let modes: [FillMode]
    let themeColor: Bool
    let set: (ConfigurationValue) -> Void
    @State private var fill: FillChoice
    @State private var mode: FillMode
    @State private var hasDarkVariant: Bool
    @State private var editingDark: Bool
    @State private var stop = 0
    @State private var color: HSVA
    @State private var stopDragOrigin: Double?
    @State private var written: ConfigurationValue
    @State private var dragWrite: Task<Void, Never>?
    @State private var isDragging = false
    @Environment(\.colorScheme) private var colorScheme

    private static let presets: [(title: String, gradient: GradientChoice)] = [
        ("Accent to critical", GradientChoice(colors: [.token("accent"), .token("critical")], angle: 120)),
        ("Accent to surface", GradientChoice(colors: [.token("accent"), .token("surface")], angle: 90)),
        ("Sheen", GradientChoice(colors: [.color(HexColor(0xffffff40)), .color(HexColor(0xffffff0a))], angle: 180)),
        ("Fade out", GradientChoice(colors: [.token("surfaceRaised"), .color(HexColor(0))], angle: 90)),
        ("Warning to critical", GradientChoice(colors: [.token("warning"), .token("critical")], angle: 90))
    ]

    init(title: String, value: ConfigurationValue?, tokens: [ThemeTokenColor], allowsGradient: Bool, allowsNone: Bool,
         themeColor: Bool, dark: Bool, set: @escaping (ConfigurationValue) -> Void) {
        let fill = FillChoice(value)
        self.title = title
        self.value = value
        self.tokens = tokens
        modes = [.theme, .color] + (allowsGradient ? [.gradient] : []) + (allowsNone ? [.none] : [])
        self.themeColor = themeColor
        self.set = set
        _fill = State(initialValue: fill)
        _mode = State(initialValue: Self.mode(for: fill, allowsNone: allowsNone))
        _hasDarkVariant = State(initialValue: themeColor || fill.hasDarkVariant)
        _editingDark = State(initialValue: dark)
        _color = State(initialValue: HSVA(rgba: fill.rgba(dark: dark, tokens: tokens), hue: 0))
        _written = State(initialValue: fill.configurationValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).fontWeight(.semibold)
            if themeColor {
                sidePicker
                picker
                Text("Saved in your configuration. Everything that uses \(title) follows.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Picker("Fill", selection: Binding(get: { mode }, set: { if $0 != mode { switchMode(to: $0) } })) {
                    ForEach(modes, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch mode {
                case .theme:
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible())], spacing: 2) {
                        ForEach(tokens) { token in
                            TokenChoice(token: token, tokens: tokens, isSelected: fill == .token(token.name)) {
                                fill = .token(token.name)
                                write()
                            }
                        }
                    }
                    Text("Theme colors change with the theme and with light and dark mode.").font(.subheadline).foregroundStyle(.secondary)
                case .color:
                    HStack {
                        Text("Different in Dark Mode")
                        Spacer()
                        Toggle("Different in Dark Mode", isOn: Binding(get: { hasDarkVariant }, set: { isOn in
                            hasDarkVariant = isOn
                            editingDark = isOn
                            if !isOn, case let .color(current) = fill { fill = .color(HexColor(current.light)) }
                            loadColor()
                            write()
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                    if hasDarkVariant { sidePicker }
                    picker
                case .gradient:
                    if case let .gradient(gradient) = fill { gradientEditor(gradient) }
                    picker
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Use a theme color for this stop").font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 5) {
                            ForEach(tokens) { token in
                                ChipButton(title: token.title, cornerRadius: 10) {
                                    editGradient { $0.stops[stop].color = .token(token.name) }
                                    loadColor()
                                    write()
                                } label: {
                                    FillChip(fill: .token(token.name), tokens: tokens, width: 20, height: 20, cornerRadius: 10)
                                }
                            }
                        }
                    }
                    HStack {
                        Text("Presets").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 5) {
                            ForEach(Self.presets, id: \.title) { preset in
                                ChipButton(title: preset.title, cornerRadius: 5) {
                                    fill = .gradient(preset.gradient)
                                    stop = 0
                                    loadColor()
                                    write()
                                } label: {
                                    GradientSwatch(stops: preset.gradient.stops, angle: preset.gradient.angle, tokens: tokens)
                                        .frame(width: 30, height: 18)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.gray.opacity(0.35)))
                                }
                            }
                        }
                    }
                case .none:
                    Text("No background. The bar shows through.").foregroundStyle(.secondary).padding(.vertical, 4).padding(.horizontal, 2)
                }
            }
        }
        .font(.callout)
        .frame(width: 244)
        .padding(10)
        .onChange(of: value) {
            if !isDragging, FillChoice(value).configurationValue != written { reload() }
        }
    }

    private static func mode(for fill: FillChoice, allowsNone: Bool) -> FillMode {
        switch fill {
        case .token: .theme
        case .color: .color
        case .gradient: .gradient
        case .none: allowsNone ? .none : .theme
        }
    }

    private func reload() {
        fill = FillChoice(value)
        mode = Self.mode(for: fill, allowsNone: modes.contains(.none))
        hasDarkVariant = themeColor || fill.hasDarkVariant
        stop = 0
        written = fill.configurationValue
        loadColor()
    }

    private var sidePicker: some View {
        Picker("Appearance", selection: Binding(get: { editingDark }, set: { editingDark = $0; loadColor() })) {
            Text("☀︎ Light").tag(false)
            Text("☾ Dark").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var picker: some View {
        InlineColorPicker(color: $color) { colorChanged(dragging: $0) }
    }

    private func gradientEditor(_ gradient: GradientChoice) -> some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let width = proxy.size.width - 14
                ZStack(alignment: .topLeading) {
                    GradientSwatch(stops: gradient.stops, angle: 90, tokens: tokens)
                        .background(Checkerboard())
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.gray.opacity(0.3)))
                        .frame(height: 26)
                        .padding(.horizontal, 7)
                    ForEach(gradient.stops.indices, id: \.self) { index in
                        let isSelected = index == stop
                        RoundedRectangle(cornerRadius: 4)
                            .fill(HexColor(gradient.stops[index].color.rgba(dark: colorScheme == .dark, tokens: tokens)).color)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white, lineWidth: 2))
                            .frame(width: 14, height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(isSelected ? Color.accentColor : .black.opacity(0.35), lineWidth: isSelected ? 2 : 1)
                                .padding(isSelected ? -2 : -1))
                            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                            .position(x: 7 + gradient.stops[index].location * width, y: 27)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if stopDragOrigin == nil { beginStopDrag(at: CGPoint(x: drag.startLocation.x - 7, y: drag.startLocation.y), width: width) }
                        editGradient { $0.stops[stop].location = (min(max(stopDragOrigin! + drag.translation.width / width, 0), 1) * 100).rounded() / 100 }
                        write(dragging: true)
                    }
                    .onEnded { _ in
                        stopDragOrigin = nil
                        write()
                    })
            }
            .frame(height: 34)
            .padding(.horizontal, -7)
            .help("Click to add a stop")
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                    .overlay {
                        Capsule().fill(Color.accentColor).frame(width: 2, height: 11).offset(y: -5.5).rotationEffect(.degrees(Double(gradient.angle)))
                    }
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            var angle = Int((atan2(drag.location.y - 15, drag.location.x - 15) * 180 / .pi + 90).rounded())
                            if NSEvent.modifierFlags.contains(.shift) { angle = Int((Double(angle) / 15).rounded()) * 15 }
                            editGradient { $0.angle = (angle % 360 + 360) % 360 }
                            write(dragging: true)
                        }
                        .onEnded { _ in write() })
                    .help("Drag to turn. Shift snaps to 15°")
                HStack(spacing: 3) {
                    TextField("Angle", value: Binding(get: { gradient.angle }, set: { angle in
                        editGradient { $0.angle = (angle % 360 + 360) % 360 }
                        write()
                    }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                    Text("°").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove stop") {
                    editGradient { $0.stops.remove(at: stop) }
                    stop = 0
                    loadColor()
                    write()
                }
                .controlSize(.small)
                .disabled(gradient.stops.count < 3)
            }
        }
    }

    private func beginStopDrag(at point: CGPoint, width: Double) {
        editGradient { gradient in
            if let hit = gradient.stops.indices.last(where: { abs(gradient.stops[$0].location * width - point.x) <= 7 && point.y >= 20 }) {
                stop = hit
            } else {
                let location = (min(max(point.x / width, 0), 1) * 100).rounded() / 100
                let nearest = gradient.stops.min { abs($0.location - location) < abs($1.location - location) }!
                gradient.stops.append(GradientChoice.Stop(color: nearest.color, location: location))
                stop = gradient.stops.count - 1
            }
            stopDragOrigin = gradient.stops[stop].location
        }
        loadColor()
    }

    private func switchMode(to next: FillMode) {
        let current = FillChoice.color(HexColor(workingRGBA))
        mode = next
        stop = 0
        switch next {
        case .theme: break
        case .color:
            fill = current
            hasDarkVariant = false
        case .gradient: fill = .gradient(GradientChoice(colors: [current, .token("accent")], angle: 90))
        case .none: fill = .none
        }
        loadColor()
        write()
    }

    private var workingRGBA: UInt32 {
        if case let .gradient(gradient) = fill { return gradient.stops[stop].color.rgba(dark: editingDark, tokens: tokens) }
        return fill.rgba(dark: editingDark, tokens: tokens)
    }

    private func loadColor() {
        color = HSVA(rgba: workingRGBA, hue: color.hue)
    }

    private func colorChanged(dragging: Bool) {
        let rgba = color.rgba
        switch fill {
        case var .gradient(gradient):
            gradient.stops[stop].color = .color(HexColor(rgba))
            fill = .gradient(gradient)
        case let .color(current) where hasDarkVariant:
            fill = .color(editingDark ? HexColor(light: current.light, dark: rgba) : HexColor(light: rgba, dark: current.dark))
        default:
            fill = .color(HexColor(rgba))
        }
        write(dragging: dragging)
    }

    private func editGradient(_ edit: (inout GradientChoice) -> Void) {
        guard case var .gradient(gradient) = fill else { return }
        edit(&gradient)
        fill = .gradient(gradient)
    }

    private func write(dragging: Bool = false) {
        isDragging = dragging
        dragWrite?.cancel()
        if dragging {
            dragWrite = Task {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                commit()
            }
        } else {
            commit()
        }
    }

    private func commit() {
        let value = fill.configurationValue
        guard value != written else { return }
        written = value
        set(value)
    }
}

private struct HSVA: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double
    var alpha: Double

    init(rgba: UInt32, hue: Double) {
        let color = NSColor(srgbRed: CGFloat(rgba >> 24) / 255, green: CGFloat((rgba >> 16) & 0xff) / 255,
                            blue: CGFloat((rgba >> 8) & 0xff) / 255, alpha: CGFloat(rgba & 0xff) / 255)
        saturation = color.saturationComponent
        brightness = color.brightnessComponent
        alpha = color.alphaComponent
        self.hue = saturation == 0 || brightness == 0 ? hue : color.hueComponent
    }

    var rgba: UInt32 {
        let color = NSColor(colorSpace: .sRGB, hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
        let byte = { (component: CGFloat) in UInt32((min(max(component, 0), 1) * 255).rounded()) }
        return byte(color.redComponent) << 24 | byte(color.greenComponent) << 16 | byte(color.blueComponent) << 8 | byte(color.alphaComponent)
    }
}

private struct InlineColorPicker: View {
    @Binding var color: HSVA
    let changed: (_ dragging: Bool) -> Void
    @State private var hex = ""
    @FocusState private var isHexFocused: Bool

    private var hexText: String { String(format: "#%06X", color.rgba >> 8) }

    var body: some View {
        let opaque = Color(hue: color.hue, saturation: color.saturation, brightness: color.brightness)
        VStack(spacing: 9) {
            GeometryReader { proxy in
                ZStack {
                    Color(hue: color.hue, saturation: 1, brightness: 1)
                    LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { knob(size: 14, fill: opaque).position(x: color.saturation * proxy.size.width, y: (1 - color.brightness) * proxy.size.height) }
                .contentShape(Rectangle())
                .gesture(drag { location in
                    color.saturation = min(max(location.x / proxy.size.width, 0), 1)
                    color.brightness = 1 - min(max(location.y / proxy.size.height, 0), 1)
                })
                .onHover { $0 ? NSCursor.crosshair.push() : NSCursor.pop() }
            }
            .frame(height: 130)
            track(color.hue) {
                LinearGradient(colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) }, startPoint: .leading, endPoint: .trailing)
            } set: { color.hue = $0 }
            track(color.alpha) {
                ZStack {
                    Checkerboard()
                    LinearGradient(colors: [opaque.opacity(0), opaque], startPoint: .leading, endPoint: .trailing)
                }
            } set: { color.alpha = $0 }
            HStack(spacing: 7) {
                FillChip(fill: .color(HexColor(color.rgba)), tokens: [])
                TextField("Hex color", text: $hex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($isHexFocused)
                    .onSubmit(applyHex)
                Text(color.alpha, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .onAppear { hex = hexText }
        .onChange(of: color) { hex = hexText }
        .onChange(of: isHexFocused) { if !isHexFocused { applyHex() } }
    }

    private func applyHex() {
        guard hex != hexText else { return }
        let digits = hex.trimmingCharacters(in: .whitespaces).trimmingPrefix("#")
        if let parsed = try? ConfigurationValue.string("#\(digits)").decoded(HexColor.self) {
            let alpha = color.alpha
            color = HSVA(rgba: parsed.light, hue: color.hue)
            if digits.count == 6 { color.alpha = alpha }
            changed(false)
        }
        hex = hexText
    }

    private func drag(_ update: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged {
                update($0.location)
                changed(true)
            }
            .onEnded { _ in changed(false) }
    }

    private func track<Background: View>(_ value: Double, @ViewBuilder background: () -> Background,
                                          set: @escaping (Double) -> Void) -> some View {
        let background = background()
        return GeometryReader { proxy in
            background
                .clipShape(Capsule())
                .overlay { knob(size: 13, fill: .clear).position(x: value * proxy.size.width, y: proxy.size.height / 2) }
                .contentShape(Rectangle())
                .gesture(drag { set(min(max($0.x / proxy.size.width, 0), 1)) })
        }
        .frame(height: 12)
    }

    private func knob(size: Double, fill: Color) -> some View {
        Circle()
            .fill(fill)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.35)).padding(-1))
            .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
    }
}

private struct TokenChoice: View {
    let token: ThemeTokenColor
    let tokens: [ThemeTokenColor]
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                FillChip(fill: .token(token.name), tokens: tokens)
                Text(token.title).lineLimit(1)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(isHovered ? 0.07 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 1.5).opacity(isSelected ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ChipButton<Label: View>: View {
    let title: String
    let cornerRadius: Double
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label
                .overlay(RoundedRectangle(cornerRadius: cornerRadius + 2).strokeBorder(Color.accentColor, lineWidth: 2).padding(-2).opacity(isHovered ? 1 : 0))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct FillChip: View {
    let fill: FillChoice
    let tokens: [ThemeTokenColor]
    var width = 18.0
    var height = 18.0
    var cornerRadius = 5.0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Checkerboard()
            switch fill {
            case .none:
                Color.clear
            case let .color(color) where color.light != color.dark:
                LinearGradient(stops: [.init(color: HexColor(color.light).color, location: 0.5), .init(color: HexColor(color.dark).color, location: 0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            case let .gradient(gradient):
                GradientSwatch(stops: gradient.stops, angle: gradient.angle, tokens: tokens)
            default:
                HexColor(fill.rgba(dark: colorScheme == .dark, tokens: tokens)).color
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.gray.opacity(0.4)))
    }
}

private struct GradientSwatch: View {
    let stops: [GradientChoice.Stop]
    let angle: Int
    let tokens: [ThemeTokenColor]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let gradient = Gradient(stops: stops.sorted { $0.location < $1.location }.map {
            Gradient.Stop(color: HexColor($0.color.rgba(dark: colorScheme == .dark, tokens: tokens)).color, location: $0.location)
        })
        let radians = Double(angle) * .pi / 180
        Canvas { context, size in
            let direction = CGSize(width: sin(radians), height: -cos(radians))
            let half = (abs(size.width * direction.width) + abs(size.height * direction.height)) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(gradient,
                startPoint: CGPoint(x: center.x - direction.width * half, y: center.y - direction.height * half),
                endPoint: CGPoint(x: center.x + direction.width * half, y: center.y + direction.height * half)))
        }
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var squares = Path()
            for row in 0..<Int((size.height / 4).rounded(.up)) {
                for column in stride(from: (row + 1) % 2, to: Int((size.width / 4).rounded(.up)), by: 2) {
                    squares.addRect(CGRect(x: Double(column) * 4, y: Double(row) * 4, width: 4, height: 4))
                }
            }
            context.fill(squares, with: .color(Color(white: 0.77)))
        }
    }
}
