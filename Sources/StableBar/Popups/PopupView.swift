import SwiftUI

struct PopupView: View {
    let popup: PopupConfiguration
    let style: WidgetStyle
    let store: BarStore
    let widget: WidgetConfiguration
    var backgrounds: PopupBackgrounds?
    var navigation = PopupNavigation()
    var size: PopupSize?
    @Environment(\.screenKind) private var screenKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: ModePresentation {
        let roles = store.configuration?.look(on: screenKind).roles ?? [:]
        guard style.usesModeStates || popup.usesModeStates(roles: roles)
            || store.widgetScripts.scripts[widget.id]?.output.styles?.values.contains(where: \.usesModeStates) == true else { return ModePresentation() }
        return store.barPresentation.modePresentation(on: screenKind)
    }

    var presentationStyle: WidgetStyle { style.resolved(for: StyleStates(mode: mode)) }

    var body: some View {
        let script = store.widgetScripts.scripts[widget.id]
        let states = StyleStates(mode: mode)
        let appearance = WidgetAppearance(presentationStyle, defaults: WidgetStyle(spacing: PopupConfiguration.blockSpacing))
        let fields = script?.output.fields ?? [:]
        let lists = script?.output.lists ?? [:]
        let samples = script?.samples ?? []
        let menu = script?.output.menu ?? widget.menu ?? []
        let error = script?.error ?? store.widgetScripts.actionErrors[widget.id]
        let fillsHeight = store.popup.pins.resized.contains(widget.id)
        let content = VStack(alignment: .leading, spacing: appearance.spacing) {
                // The layout always slides in from and out to the leading edge and a view the trailing one, so going in and
                // coming back both read right, whatever each was last drawn with.
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: appearance.spacing) {
                        let view = navigation.view.map { popup.views[$0]! }
                        if let view, !view.startsWithTitle(fields: fields, values: script?.output.values ?? [:]) {
                            CornerButton(symbol: "chevron.left", label: "Back", foreground: appearance.foreground) { navigation.view = nil }
                        }
                        PopupBlockView(block: view ?? popup.layout, inheritedStyle: style, fields: fields,
                                       context: BlockContext(lists: lists, samples: samples, menu: menu,
                                                             values: script?.output.values ?? [:], targets: script?.output.targets ?? [:],
                                                             styles: script?.output.styles ?? [:], series: script?.output.series ?? [:],
                                                             roles: store.configuration?.look(on: screenKind).roles ?? [:], open: { target in
                            guard store.barEditing.allowsWidgetActions else { return }
                            if popup.dismissOnAction { store.popup.close() }
                            target.open()
                        }, openView: { navigation.view = $0 }, quit: { pid in
                            guard store.barEditing.allowsWidgetActions else { return }
                            if popup.dismissOnAction { store.popup.close() }
                            confirmQuit(pid)
                        }, eject: { path, scope in
                            guard store.barEditing.allowsWidgetActions else { return }
                            try await VolumeEjector.live.eject(path, scope)
                        }, stateAccents: popupStateAccents(style, mode: mode),
                           dataState: dataState(script?.output, rules: widget.rules), pressMenuBarItem: { reference in
                            guard store.barEditing.allowsWidgetActions else { return }
                            if popup.dismissOnAction { store.popup.close() }
                            store.appMenu.press(reference)
                        }, selectInputSource: { id in
                            guard store.barEditing.allowsWidgetActions else { return }
                            if popup.dismissOnAction { store.popup.close() }
                            store.widgetScripts.selectInputSource(id, widget: widget)
                        }, selectAudioDevice: { id, input in
                            guard store.barEditing.allowsWidgetActions else { return }
                            if popup.dismissOnAction { store.popup.close() }
                            store.widgetScripts.selectAudioDevice(id, input: input, widget: widget)
                        }, providerOutput: { store.widgetScripts.providers[$0]?.output }, openSubmenu: { [screenKind] element, row in
                            store.appMenu.openSubmenu(element, beside: row) { submenu in
                                PopupView(popup: submenu, style: style, store: store, widget: widget).environment(\.screenKind, screenKind)
                            }
                        }, pressMenuItem: { entry in
                            store.popup.close()
                            store.appMenu.press(entry)
                        }, openMenuBarItem: { [screenKind] element, anchor in
                            guard let element else { return store.innerPopup.close() }
                            let look = store.configuration!.onScreen(screenKind)
                            store.innerPopup.toggle(store.appMenu.popup(forMenuBarItem: element), widget: widget,
                                                    defaults: look.popupDefaults.popupStyle(over: look.defaults), store: store, anchor: anchor)
                        }, hoverMenuBarItem: { [screenKind] title, anchor, inside in
                            let look = store.configuration!.onScreen(screenKind)
                            store.innerPopup.hover(inside, store: store, anchor: anchor) {
                                store.innerPopup.showTooltip(title, widget: widget, defaults: look.popupDefaults.popupStyle(over: look.defaults),
                                                             store: store, anchor: anchor)
                            }
                        }, menuBarItemAnchor: store.barPresentation.presentations[widget.id]?.innerPopupAnchor, placeMenuBarItem: { item, placement in
                            store.popup.close()
                            store.widgetScripts.move(.item(item), to: placement, before: nil, in: widget)
                        }, states: states, update: store.update) { action, environment in
                            if environment.isEmpty ? popup.dismissOnAction : popup.dismissOnControl { store.popup.close() }
                            store.widgetScripts.runAction(action, widget: widget,
                                                          event: ScriptEvent(sender: environment.isEmpty ? "mouse.clicked" : "control.changed", environment: environment))
                        }, topLevel: true, back: view == nil ? nil : { navigation.view = nil })
                    }
                    .id(navigation.view)
                    .transition(reduceMotion ? .opacity : .move(edge: navigation.view == nil ? .leading : .trailing).combined(with: .opacity))
                }
                // Focus rings reach a few points past the controls.
                .clipShape(Rectangle().inset(by: -8))
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(.horizontal, appearance.paddingHorizontal)
            .padding(.vertical, appearance.paddingVertical)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: PopupHeightPreference.self, value: proxy.size.height)
                }
            }
            .environment(\.popupFillsHeight, fillsHeight)
            // With an animation of its own, a popup also animates what its data changes, as it animates its height.
            .animation(reduceMotion ? nil : popup.animation?.value, value: script?.outputNumber)
            .animation((popup.animation ?? WidgetAnimation()).value, value: navigation.view)
        Group {
            // A popup resized by hand gives its height to the fields that scroll instead of scrolling as a whole.
            if fillsHeight {
                content.frame(maxHeight: .infinity, alignment: .top)
            } else {
                // A popup as tall as its content has nothing to scroll, yet while its height animates to taller content,
                // its scroll view would show a scroll bar. Blocks inside keep their own scroll bars.
                ScrollView { content.scrollIndicators(.automatic) }
                    .scrollIndicators(size?.followsContent == true ? .never : .automatic)
            }
        }
        .overlay(alignment: .topTrailing) {
            if popup.pinnable {
                let pinned = store.popup.pins.ids.contains(widget.id)
                PinControls(pinned: pinned, foreground: appearance.foreground) {
                    if pinned { store.popup.unpin(widget.id) } else { store.popup.pin() }
                } close: {
                    store.popup.closePinned(widget.id)
                }
            }
        }
        .modifier(PopupBackground(style: presentationStyle, glass: store.configuration?.bar(on: screenKind).glass ?? GlassSettings(),
                                  backgrounds: backgrounds ?? store.popup.backgrounds))
        .tint(appearance.accent)
        .focusEffectDisabled()
        .accessibilityIdentifier("\(widget.id)-popup")
    }
}

struct PopupBackground: ViewModifier {
    let style: WidgetStyle
    let glass: GlassSettings
    let backgrounds: PopupBackgrounds
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let hidden = backgrounds.hidden
        content
            .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius))
            .modifier(GlassBackground(fill: hidden ? .color(HexColor(0)) : style.background, glass: glass, surface: \.popups,
                                      shape: RoundedRectangle(cornerRadius: appearance.cornerRadius)))
            .overlay {
                RoundedRectangle(cornerRadius: appearance.cornerRadius)
                    .strokeBorder(hidden ? .clear : appearance.border(increasedContrast: contrast == .increased),
                                  lineWidth: contrast == .increased ? max(appearance.borderWidth, 1) : appearance.borderWidth)
            }
    }
}

struct PopupHeightPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The accent the widget's style gives each of the data states a disk widget warns in.
func popupStateAccents(_ style: WidgetStyle, mode: ModePresentation) -> [String: Color] {
    ["warning", "critical"].reduce(into: [:]) { accents, name in
        guard style.states?[name]?.accent != nil else { return }
        let resolved = style.resolved(for: StyleStates(data: name, mode: mode))
        accents[name] = WidgetAppearance(resolved, defaults: WidgetStyle()).accent
    }
}

/// A pinnable popup's pin button, and its close button while it's pinned.
private struct PinControls: View {
    let pinned: Bool
    let foreground: Color
    let togglePin: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if pinned {
                CornerButton(symbol: "xmark", label: "Close", foreground: foreground, action: close)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            CornerButton(symbol: pinned ? "pin.fill" : "pin", label: pinned ? "Unpin" : "Pin", foreground: foreground, action: togglePin)
                .symbolEffect(.bounce, value: pinned)
        }
        .padding(4)
        .animation(.snappy(duration: 0.3), value: pinned)
    }
}

struct CornerButton: View {
    let symbol: String
    let label: String
    let foreground: Color
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(foreground.opacity(hovered ? 0.12 : 0), in: Circle())
                .overlay { if focused { FocusRingShape(shape: Circle(), outset: 0) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .foregroundStyle(foreground.opacity(hovered || focused ? 0.9 : 0.55))
        .help(label)
        .accessibilityLabel(label)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}
