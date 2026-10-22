import AppKit
import SwiftUI

extension ScreenKind {
    var screens: [NSScreen] { NSScreen.screens.filter { ScreenKind(BarDisplay(screen: $0)) == self } }

    var name: String {
        switch self {
        case .laptop: "Laptop"
        case .monitor, .vertical: screens.count == 1 ? screens[0].localizedName : title
        }
    }

    var screenTitle: String { self == .laptop ? "Laptop screen" : name }

    var phrase: String {
        switch self {
        case .laptop: "the laptop screen"
        case .monitor, .vertical: screens.count == 1 ? "the \(name)" : title.lowercased()
        }
    }

    var symbol: String {
        switch self {
        case .laptop: "laptopcomputer"
        case .monitor: "display"
        case .vertical: "rectangle.portrait"
        }
    }

    var display: BarDisplay {
        screens.first.map(BarDisplay.init) ?? BarDisplay(id: 0, isBuiltIn: self == .laptop, isMain: false, notch: nil, isPortrait: self == .vertical)
    }
}

struct Wallpaper: View {
    static let image = Bundle.main.url(forResource: "SetupAmberLight", withExtension: "heic").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        GeometryReader { geometry in
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    .clipped()
            } else {
                SettingsPalette.background
            }
        }
    }
}

struct ScreenBand: View {
    let editor: ConfigurationEditor
    let kinds: [ScreenKind]
    let screen: ScreenKind
    let useSharedBar: (ScreenSetup) -> Void
    private var store: BarStore { editor.store }

    var body: some View {
        HStack(spacing: 16) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(kinds, id: \.self) { kind in
                    ScreenThumbnail(store: store, kind: kind, selected: kind == screen) { editor.barScreen = kind }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Editing the bar on").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(screen.screenTitle).font(.system(size: 15, weight: .semibold)).padding(.top, 1).padding(.bottom, 3)
                if let setup = store.screenSetup {
                    HStack(spacing: 8) {
                        setupMenu(setup)
                        ProfilePicker(editor: editor)
                    }
                    if setup != ScreenSetup(NSScreen.screens.map(BarDisplay.init)) {
                        Text("Previewing a setup that isn’t connected").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 3)
                    }
                }
            }
            Spacer()
            Button(store.barEditing.menuTitle, action: store.barEditing.toggle)
                .disabled(!store.barEditing.isAvailable)
        }
    }

    private func setupMenu(_ setup: ScreenSetup) -> some View {
        let displays = NSScreen.screens.map(BarDisplay.init)
        let connected = ScreenSetup(displays)
        let ownBars = store.screenSetupsWithOwnBars
        let name = { (setup: ScreenSetup) in setup.title + (setup == connected ? " (connected)" : "") }
        return Menu {
            ForEach(store.screenSetupsToEdit(connected: displays), id: \.fileName) { option in
                Toggle("\(name(option)) · \(ownBars.contains(option) ? "own bar" : "shared bar")",
                       isOn: Binding(get: { option == setup }, set: { _ in store.showScreenSetup(option) }))
            }
            Divider()
            if ownBars.contains(setup) {
                Button("Use the shared bar again…") { useSharedBar(setup) }
            } else {
                Button("Give it its own bar") { giveOwnBar() }
                Menu("Copy bar from") {
                    Button("The shared bar") { giveOwnBar() }
                    ForEach(ownBars, id: \.fileName) { other in
                        Button(other.title) { giveOwnBar(copying: store.ownBarURL(for: other)) }
                    }
                }
            }
        } label: {
            Text("\(name(setup)) · \(ownBars.contains(setup) ? "own bar" : "shared bar")")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    private func giveOwnBar(copying source: URL? = nil) {
        do { try store.giveScreenSetupItsOwnBar(copying: source) }
        catch { editor.error = errorMessage(error) }
    }
}

struct ScreenSetupPopover: View {
    let editor: ConfigurationEditor
    let setup: ScreenSetup
    let title: String
    let useSharedBar: (ScreenSetup) -> Void
    @Environment(\.dismiss) private var dismiss
    private var store: BarStore { editor.store }

    var body: some View {
        let ownsBar = store.configurationURL != store.sharedConfigurationURL
        let others = store.screenSetupsWithOwnBars.filter { $0 != setup }
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(ownsBar
                 ? "These screens have their own bar, saved beside your configuration. Changes here apply only while they’re connected."
                 : "These screens use your shared bar, like every set of screens without its own. Give them their own bar to change it only while they’re connected.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if ownsBar {
                    Button("Use the shared bar again…") { useSharedBar(setup) }
                } else {
                    Button("Give them their own bar") {
                        do { try store.giveScreenSetupItsOwnBar() }
                        catch { editor.error = errorMessage(error) }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            if !others.isEmpty {
                Divider()
                Text("Other screens with their own bar").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(others, id: \.fileName) { other in
                    HStack {
                        Text(other.title).font(.system(size: 12))
                        Spacer()
                        Button("Use shared bar…") { useSharedBar(other) }
                    }
                }
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(width: 300)
    }
}

private struct ScreenThumbnail: View {
    let store: BarStore
    let kind: ScreenKind
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        let size = switch kind {
        case .laptop: CGSize(width: 82, height: 52)
        case .monitor: CGSize(width: 96, height: 54)
        case .vertical: CGSize(width: 36, height: 56)
        }
        let notched = kind.display.notch != nil
        Button(action: select) {
            VStack(spacing: 4) {
                Wallpaper()
                    .overlay(alignment: .top) {
                        HStack(spacing: 2) {
                            blocks([.left, .notchLeft])
                            Spacer(minLength: 0)
                            if notched {
                                blocks([.notchRight, .center, .right])
                            } else {
                                blocks([.center])
                                Spacer(minLength: 0)
                                blocks([.right])
                            }
                        }
                        .padding(.horizontal, 2)
                        .frame(height: 8)
                        .background(barColor, in: RoundedRectangle(cornerRadius: min(3, store.barStyle(on: kind).cornerRadius ?? 0)))
                        .padding(2)
                    }
                    .overlay(alignment: .top) {
                        if notched { UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3).fill(.black).frame(width: 18, height: 9) }
                    }
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selected ? Color.accentColor : hovering ? Color(nsColor: .tertiaryLabelColor) : SettingsPalette.groupBorder,
                                          lineWidth: selected ? 2.5 : 1)
                    }
                Text(kind.name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(width: size.width)
            .padding(3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .overlay(alignment: .bottomTrailing) {
            Menu { menu } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering || selected ? 1 : 0)
                .help("Split or copy this screen’s bar")
                .accessibilityLabel("\(kind.name) bar options")
        }
        .accessibilityLabel(kind.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var menu: some View {
        let setup = WidgetSetup(store: store)
        let split = store.configuration?.screenLayouts[kind.rawValue] != nil || store.configuration?.screenLooks[kind.rawValue] != nil
        Toggle("Own layout and size for this screen", isOn: Binding(get: { split }, set: { own in
            change { own ? try setup.splitScreen(kind) : try setup.joinScreen(kind) }
        }))
        let others = ScreenKind.allCases.filter { $0 != kind && store.screenSetup?.kinds.contains($0) == true }
        if !others.isEmpty {
            Menu("Copy from") {
                ForEach(others, id: \.self) { other in
                    Button(other.name) { change { try setup.copyScreen(other, to: kind) } }
                }
            }
        }
    }

    private func change(_ action: () throws -> Void) {
        do { try action() }
        catch { store.customizationHistory.error = errorMessage(error) }
    }

    private func blocks(_ positions: [WidgetPosition]) -> some View {
        let displays = NSScreen.screens.map(BarDisplay.init)
        let widgets = (store.configuration?.onScreen(kind).widgets ?? []).filter {
            positions.contains($0.position) && $0.enabled && kind.shows($0.display, among: displays, activeID: store.activeDisplayID)
        }
        return ForEach(widgets) { widget in
            Capsule().fill(color(widget)).frame(width: widget.content.isClock ? 13 : 7, height: 4)
        }
    }

    private var barColor: AnyShapeStyle {
        (store.barStyle(on: kind).background ?? store.configuration?.onScreen(kind).bar.background)?.shapeStyle ?? AnyShapeStyle(Color.clear)
    }

    private func color(_ widget: WidgetConfiguration) -> Color {
        let look = store.configuration?.onScreen(kind)
        let style = resolveStyle([look?.defaults ?? WidgetStyle(), look?.roleStyle(widget.role) ?? WidgetStyle(), widget.style])
        return (style.background?.firstColor ?? style.foreground)?.color ?? .secondary
    }
}

private extension WidgetContent {
    var isClock: Bool {
        if case .clock = self { true } else { false }
    }
}
