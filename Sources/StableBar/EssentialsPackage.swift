import Foundation

func upgradedEssentialsPackage(_ layer: ConfigurationLayer, manifest: WidgetPackageManifest,
                              settings: [String: ConfigurationValue]) throws -> ConfigurationLayer {
    var values = layer.values
    var widgets = try values["widgets"]!.decoded([[String: ConfigurationValue]].self)
    var widget = widgets[0]
    widget["details"] = .bool(true)
    widget["popupName"] = nil
    switch manifest.id {
    case "date": widget["open"] = nil
    case "battery-status", "calendar-agenda": widget["layout"] = nil
    case "system-monitor":
        widget["rules"] = nil
        var providers = try values["providers"]!.decoded([String: [String: ConfigurationValue]].self)
        var system = providers["system"]!
        let settings = try manifest.values(settings)
        for key in ["sortBy", "cpuWarning", "memoryWarning"] {
            system[key] = settings[key]
        }
        providers["system"] = system
        values["providers"] = .object(providers.mapValues(ConfigurationValue.object))
    default: break
    }
    widgets[0] = widget
    values["widgets"] = .array(widgets.map(ConfigurationValue.object))
    let source = layer.origins["widgets.\(manifest.id).id"]!.appending("(StableBar Essentials)")
    return ConfigurationLayer(values: values, origins: configurationOrigins(.object(values), source: source))
}
