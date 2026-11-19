import SwiftUI

/// The same controls edit global defaults or an individual workspace widget through shared edits.
struct WorkspacePresentationFields: View {
    let store: BarStore
    let path: String
    var defaultsPath: String?
    var widgetID: String?
    let values: [String: ConfigurationValue]
    let set: ([String: ConfigurationValue]) -> Void
    let unset: ([String: ConfigurationValue]) -> Void

    var body: some View {
        let root = StyleFields(store: store, path: path, defaultsPath: defaultsPath, widgetID: widgetID,
                               values: values, set: set, unset: unset)
        let indicator = fields("indicatorStyle")
        let cell = fields("style")
        let app = fields("appStyle")
        root.choice("Indicator", "indicator", choices: ["background", "underline", "none"], default: "background")
        indicator.choice("Underline placement", "placement", choices: IndicatorPlacement.allCases.map(\.rawValue), default: "cell")
        indicator.color("Underline", "background")
        indicator.number("Underline thickness", "height", default: 2)
        indicator.number("Underline gap / cell offset", "offsetY", default: 0, in: -200...200)
        cell.color("Workspace text", "foreground")
        cell.number("Cell height", "height", default: 22)
        cell.number("Cell padding", "paddingHorizontal", default: 7)
        cell.number("Workspace font size", "fontSize", default: 13)
        cell.weight()
        app.color("App glyphs", "foreground")
        app.font(NSFontManager.shared.availableFontFamilies)
        app.number("App glyph size", "fontSize", default: 14)
    }

    private func fields(_ key: String) -> StyleFields {
        StyleFields(store: store, path: "\(path).\(key)", defaultsPath: defaultsPath.map { "\($0).\(key)" }, widgetID: widgetID,
            values: (try? values[key]?.decoded([String: ConfigurationValue].self)) ?? [:],
            set: { set([key: .object($0)]) }, unset: { unset([key: .object($0)]) })
    }
}
