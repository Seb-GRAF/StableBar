import AppKit
import Observation

@MainActor @Observable
final class BarPresentation {
    private weak var store: BarStore?
    private(set) var presentations: [String: WidgetPresentation] = [:]
    private(set) var barStyle = WidgetStyle()
    private(set) var screenBarStyles: [String: WidgetStyle] = [:]

    init(store: BarStore) {
        self.store = store
    }

    /// Keeps one presentation per configured widget and has every running script re-resolve
    /// styles when it updates. A script reports to the first store that prepares it, so a store
    /// that only shows the bar's scripts, like the setup preview, doesn't take them over.
    func preparePresentations() {
        guard let store else { return }
        presentations = Dictionary(uniqueKeysWithValues: (store.configuration?.widgets ?? []).map {
            ($0.id, presentations[$0.id] ?? WidgetPresentation())
        })
        for script in store.widgetScripts.scripts.values where script.onUpdate == nil {
            script.onUpdate = { [weak self] in self?.updatePresentations() }
        }
        updatePresentations()
    }

    /// Resolves every widget's style and presence and the bar's style from the configuration and the
    /// current outputs. Only changed values are assigned, so views of unaffected widgets stay valid.
    func updatePresentations() {
        guard let store, let configuration = store.configuration else { return }
        let output = { (id: String) in store.widgetScripts.scripts[id]?.output }
        let overrides = OrderedStyleOverrides(widgets: configuration.widgets, output: output)
        let outputNeedsMode = overrides.bar.usesModeStates || overrides.widgets.values.contains(where: \.usesModeStates)
            || store.widgetScripts.scripts.values.contains { $0.output.style?.usesModeStates == true || $0.output.styles?.values.contains(where: \.usesModeStates) == true }
        if store.managesConnections {
            store.workspaceStore.configure(source: configuration.workspaceSource,
                                           workspaces: configuration.widgets.contains { $0.enabled && ($0.content == .workspaces || $0.display == .active) },
                                           mode: configuration.needsModeConnection || outputNeedsMode)
        }
        let mode = modePresentation
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let screenOverrides = configuration.screenLooks.mapValues { OrderedStyleOverrides(widgets: $0.widgets, output: output) }
        // A screen's own layout can also change which group a widget joins, and so its text color.
        let screens = ScreenKind.allCases.filter { configuration.screenLooks[$0.rawValue] != nil || configuration.screenLayouts[$0.rawValue] != nil }
        let screenWidgets = Dictionary(uniqueKeysWithValues: screens.map { kind in
            (kind, Dictionary(uniqueKeysWithValues: configuration.onScreen(kind).widgets.map { ($0.id, $0) }))
        })
        for widget in configuration.widgets {
            let script = store.widgetScripts.scripts[widget.id]
            let base = resolveStyle(widgetStyleLayers(widget, defaults: configuration.defaults, overrides: overrides, own: script?.output,
                                                      role: configuration.roleStyle(widget.role), group: configuration.groupStyle(of: widget)))
            let usesMode = base.usesModeStates || configuration.usesSliderModeStates(widget) || widget.layout?.usesModeStates(roles: configuration.roles) == true
                || widget.hoverLayout?.usesModeStates(roles: configuration.roles) == true
                || widget.overlay?.usesModeStates(roles: configuration.roles) == true
                || script?.output.styles?.values.contains(where: \.usesModeStates) == true
            let animation = script?.output.animation ?? widget.animation ?? configuration.bar.animation
            let states = widgetDataStates(script?.output, widget: widget, providers: configuration.providers)
            let hidesWhenEmpty = switch widget.content {
            case .script: true
            case let .provider(name): configuration.providers[name]?.whenVisible != true
            default: false
            }
            var screenStyles: [String: ResolvedWidgetStyle] = [:]
            for kind in screens {
                guard let own = screenWidgets[kind]![widget.id] else { continue }
                let look = configuration.look(on: kind)
                let base = resolveStyle(widgetStyleLayers(own, defaults: look.defaults, overrides: screenOverrides[kind.rawValue] ?? overrides, own: script?.output,
                                                          role: look.roleStyle(own.role), group: look.groupStyle(of: own)))
                let screenStates = widgetDataStates(script?.output, widget: own, providers: configuration.providers)
                let screenUsesMode = usesMode || base.usesModeStates || look.usesSliderModeStates(own)
                    || own.layout?.usesModeStates(roles: look.roles) == true
                    || own.hoverLayout?.usesModeStates(roles: look.roles) == true
                    || own.overlay?.usesModeStates(roles: look.roles) == true
                screenStyles[kind.rawValue] = ResolvedWidgetStyle(base: base, state: screenStates.widget, parts: screenStates.parts,
                                                                  mode: screenUsesMode ? modePresentation(on: kind) : ModePresentation())
            }
            presentations[widget.id]?.update(style: ResolvedWidgetStyle(base: base, state: states.widget, parts: states.parts,
                                                                        mode: usesMode ? mode : ModePresentation()),
                                             screenStyles: screenStyles,
                                             hidden: (script?.output.hidden == true || hidesWhenEmpty && !store.barEditing.hasContent(widget))
                                                 && script?.error == nil,
                                             display: script?.output.display,
                                             visibility: visibilityAnimation(widget.transition ?? configuration.bar.motion.transition, animation: animation,
                                                                             reduceMotion: reduceMotion))
            presentations[widget.id]?.show(script?.output.temporary, output: script?.outputNumber ?? 0,
                                           animation: reduceMotion ? nil : animation)
        }
        let bar = resolveStyle(barStyleLayers(configuration.bar.style, overrides: overrides), states: StyleStates(mode: mode))
        if barStyle != bar { barStyle = bar }
        let kinds = ScreenKind.allCases.filter { configuration.screenLooks[$0.rawValue] != nil }
        let screenBars = Dictionary(uniqueKeysWithValues: kinds.map { kind in
            (kind.rawValue, resolveStyle(barStyleLayers(configuration.bar(on: kind).style, overrides: overrides),
                                         states: StyleStates(mode: modePresentation(on: kind))))
        })
        if screenBarStyles != screenBars { screenBarStyles = screenBars }
    }

    func barStyle(on kind: ScreenKind) -> WidgetStyle {
        screenBarStyles[kind.rawValue] ?? barStyle
    }

    var modePresentation: ModePresentation {
        guard let store else { return ModePresentation() }
        return ModePresentation(mode: store.configuration?.workspaceSource == .aerospace ? store.workspaceStore.mode : nil,
                                aliases: store.configuration?.modeAliases ?? [:])
    }

    func modePresentation(on kind: ScreenKind) -> ModePresentation {
        guard let store else { return ModePresentation() }
        return ModePresentation(mode: store.configuration?.workspaceSource == .aerospace ? store.workspaceStore.mode : nil,
                                aliases: store.configuration?.look(on: kind).modeAliases ?? [:])
    }
}
