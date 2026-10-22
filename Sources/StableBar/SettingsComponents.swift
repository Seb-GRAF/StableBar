import AppKit
import SwiftUI

enum SettingsPalette {
    static let background = dynamic(light: 0xf5f5f7ff, dark: 0x1e1e20ff)
    static let sidebar = dynamic(light: 0xebebeeff, dark: 0x252527ff)
    static let group = dynamic(light: 0xffffffff, dark: 0x2a2a2dff)
    static let groupBorder = dynamic(light: 0x00000014, dark: 0xffffff12)
    static let separator = dynamic(light: 0x00000013, dark: 0xffffff13)
    static let control = dynamic(light: 0x0000000e, dark: 0xffffff14)
    static let controlHover = dynamic(light: 0x00000017, dark: 0xffffff21)
    static let field = dynamic(light: 0xffffffff, dark: 0x00000047)
    static let selectedSegment = dynamic(light: 0xffffffff, dark: 0x5b5b60ff)
    static let profile = dynamic(light: 0xa742d8ff, dark: 0xbf5af2ff)
    static let profileSoft = dynamic(light: 0xa742d81c, dark: 0xbf5af22b)
    static let success = dynamic(light: 0x1f9d48ff, dark: 0x30d158ff)
    static let warning = dynamic(light: 0xc77700ff, dark: 0xff9f0aff)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(HexColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light).color)
        })
    }
}

extension EnvironmentValues {
    @Entry var showsValueSources = false
}

struct Scrub {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var step: Double = 1
}

private struct ScrubModifier: ViewModifier {
    let scrub: Scrub
    @State private var start: Double?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    let origin = start ?? scrub.value.wrappedValue
                    start = origin
                    let steps = (drag.translation.width / 3).rounded() * (NSEvent.modifierFlags.contains(.shift) ? 10 : 1)
                    let value = min(max(origin + steps * scrub.step, scrub.range.lowerBound), scrub.range.upperBound)
                    if value != scrub.value.wrappedValue { scrub.value.wrappedValue = value }
                }
                .onEnded { _ in start = nil })
    }
}

extension View {
    func scrubbing(_ scrub: Scrub?) -> some View {
        Group {
            if let scrub { modifier(ScrubModifier(scrub: scrub)) } else { self }
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var property: PropertySources?
    var source: String?
    var reset: (() -> Void)?
    var scrub: Scrub?
    var hint: String?
    @ViewBuilder let control: Control
    @State private var explaining = false
    @Environment(\.showsValueSources) private var showsSources

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                RevertSettingButton(title: title, property: property, reset: reset)
                control
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).scrubbing(scrub)
                if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                if showsSources, let source {
                    Button { explaining = true } label: {
                        Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(property == nil)
                    .help("Show where this value comes from")
                }
            }
        }
        .popover(isPresented: $explaining, arrowEdge: .bottom) {
            if let property { SourcePopover(title: title, property: property, reset: reset) }
        }
    }
}

struct RevertSettingButton: View {
    let title: String
    let property: PropertySources?
    let reset: (() -> Void)?
    @State private var explaining = false
    @Environment(\.showsValueSources) private var showsSources

    var body: some View {
        ZStack {
            if let reset {
                Button(action: reset) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)
                .help("Revert \(title.lowercased()) to its inherited value")
                .accessibilityLabel("Revert \(title)")
            } else if showsSources, property != nil {
                Button { explaining = true } label: {
                    Image(systemName: "info.circle")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)
                .help("Show where \(title.lowercased()) comes from")
                .accessibilityLabel("Sources for \(title)")
            }
        }
        .frame(width: 24, height: 24)
        .buttonStyle(.plain)
        .contextMenu {
            if property != nil {
                Button("Show value sources") { explaining = true }
            }
        }
        .popover(isPresented: $explaining, arrowEdge: .bottom) {
            if let property { SourcePopover(title: title, property: property, reset: reset) }
        }
    }
}

struct SourcePopover: View {
    @Environment(BarStore.self) private var store
    let title: String
    let property: PropertySources
    let reset: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(property.sources.reversed().enumerated()), id: \.offset) { index, source in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Color.accentColor)
                            .opacity(index == 0 ? 1 : 0)
                        Text(source.origin.map(store.sourceText) ?? source.title)
                            .fontWeight(index == 0 ? .semibold : .regular)
                            .foregroundStyle(index == 0 ? .primary : .secondary)
                        Spacer(minLength: 12)
                        Text((source.resolvedValue ?? source.value).sourceDescription)
                            .foregroundStyle(index == 0 ? .primary : .secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                }
            }
            if property.isMasked {
                Text("Your saved value is overridden by the source above it.").font(.caption).foregroundStyle(SettingsPalette.warning)
            }
            Text("The top value wins. The others are what you’d get without it.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if let profile = property.sources.last?.origin?.profile, let open = store.onCustomizeProfile {
                    Button("Open profile") { dismiss(); open(profile) }
                }
                Spacer()
                if let reset {
                    Button("Reset") { dismiss(); reset() }.keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct NumberField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit = "pt"
    var slider = false
    var symbol = "arrow.left.and.right"
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if slider {
                Slider(value: $value, in: range, step: step).labelsHidden().controlSize(.small).frame(width: 110)
                    .accessibilityLabel(title)
            }
            HStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 22)
                    .scrubbing(Scrub(value: $value, range: range, step: step))
                    .help("Drag to change. Hold Shift for steps of 10.")
                TextField(title, text: $text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 34)
                    .focused($focused)
                    .onSubmit(commit)
                    .onKeyPress(.upArrow) { nudge(1) }
                    .onKeyPress(.downArrow) { nudge(-1) }
                    .labelsHidden()
                if !unit.isEmpty {
                    Text(unit).font(.caption).foregroundStyle(.tertiary).frame(minWidth: 14, alignment: .leading).padding(.leading, 3)
                }
            }
            .padding(.trailing, 7)
            .frame(height: 24)
            .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor : SettingsPalette.groupBorder,
                                                                     lineWidth: focused ? 2 : 1))
        }
        .onAppear { text = formatted(value) }
        .onChange(of: value) { if !focused { text = formatted(value) } }
        .onChange(of: focused) { if !focused { commit() } }
        .onChange(of: text) {
            if focused, let number = typedNumber, range.contains(number), number != value { value = number }
        }
    }

    private var typedNumber: Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }

    private func commit() {
        guard let number = typedNumber else { text = formatted(value); return }
        let clamped = min(max(number, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
        text = formatted(clamped)
    }

    private func nudge(_ direction: Double) -> KeyPress.Result {
        let next = min(max(value + direction * step * (NSEvent.modifierFlags.contains(.shift) ? 10 : 1), range.lowerBound), range.upperBound)
        if next != value { value = next }
        text = formatted(next)
        return .handled
    }

    private func formatted(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}

struct NumberDraft<Content: View>: View {
    @Binding var value: Double
    @ViewBuilder let content: (Binding<Double>) -> Content
    @State private var draft: Double?

    var body: some View {
        content(Binding(get: { draft ?? value }, set: { draft = $0 }))
            .task(id: draft) {
                guard let draft else { return }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                value = draft
                self.draft = nil
            }
            .onDisappear { if let draft { value = draft } }
    }
}

struct TextDraft<Content: View>: View {
    @Binding var text: String
    @ViewBuilder let content: (Binding<String>) -> Content
    @State private var draft: String?

    var body: some View {
        content(Binding(get: { draft ?? text }, set: { draft = $0 }))
            .task(id: draft) {
                guard let draft else { return }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                text = draft
                self.draft = nil
            }
            .onDisappear { if let draft { text = draft } }
    }
}

struct SettingsSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var stretches = true
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.0) { option, title in
                let selected = option == selection
                Button { withAnimation(.snappy(duration: 0.2)) { selection = option } } label: {
                    Text(title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .frame(maxWidth: stretches ? .infinity : nil, minHeight: 20)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5).fill(SettingsPalette.selectedSegment)
                                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct SettingsCallout<Trailing: View>: View {
    let systemImage: String
    let text: Text
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            text.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(SettingsPalette.groupBorder))
    }
}

extension SettingsCallout where Trailing == EmptyView {
    init(systemImage: String, text: Text) {
        self.init(systemImage: systemImage, text: text) { EmptyView() }
    }
}

enum PackageSource {
    case builtIn, included, store, listed, installed, local

    var title: String {
        switch self {
        case .builtIn: "Built-in"
        case .included: "Included"
        case .store: "Store"
        case .listed: "Listed in Store"
        case .installed: "Installed"
        case .local: "Local folder"
        }
    }

    var symbol: String {
        switch self {
        case .builtIn, .included: "sparkle"
        case .store, .listed: "bag.fill"
        case .installed: "shippingbox.fill"
        case .local: "folder.fill"
        }
    }

    var tint: Color {
        switch self {
        case .builtIn, .included, .installed: .secondary
        case .store, .listed: .blue
        case .local: SettingsPalette.warning
        }
    }
}

struct PackageSourceBadge: View {
    let source: PackageSource

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: source.symbol).font(.system(size: 8, weight: .bold))
            Text(source.title)
        }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(source.tint)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(background, in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
    }

    private var background: AnyShapeStyle {
        switch source {
        case .builtIn, .included, .installed: AnyShapeStyle(SettingsPalette.control)
        case .store, .listed, .local: AnyShapeStyle(source.tint.opacity(0.15))
        }
    }
}
