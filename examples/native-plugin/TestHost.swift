import AppKit
import Foundation

@MainActor
private final class HostProbe: NSObject, StableBarNativeWidgetHost {
    var plugin: (any StableBarNativeWidgetPlugin)?
    var popupView: NSView?
    var popupRequests = 0
    var savedSettings: [String: Any]?

    func requestPopup() {
        popupRequests += 1
        popupView = plugin?.makePopupView()
    }

    func saveSettings(_ settings: [String: Any]) {
        savedSettings = settings
        plugin?.settingsDidChange?(["tapCount": 40])
    }
}

@main
@MainActor
private struct NativePluginTestHost {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let bundle = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1])) else {
            fatalError("Pass the demo .bundle path")
        }
        try bundle.loadAndReturnError()
        guard let principalClass = bundle.principalClass as? NSObject.Type,
              let instance = principalClass.init() as? StableBarNativeWidgetPlugin,
              instance.apiVersion == 1 else {
            fatalError("The bundle principal class does not implement API version 1")
        }

        let host = HostProbe()
        host.plugin = instance
        instance.configure?(with: host, settings: ["tapCount": 0])
        instance.stableBarDidReceiveEvent?("host.ready", payload: ["source": "test"])
        let eventSelector = Selector(("lastReceivedEventForTesting"))
        guard let event = (instance as? NSObject)?.perform(eventSelector)?.takeUnretainedValue() as? String,
              event == "host.ready" else {
            fatalError("The plugin did not receive the host event")
        }
        let widgetView = instance.makeWidgetView()
        _ = widgetView
        instance.start()

        let testAction = Selector(("activateDemoButtonForTesting"))
        guard (instance as? NSObject)?.responds(to: testAction) == true else {
            fatalError("The demo button action is unavailable")
        }
        (instance as? NSObject)?.perform(testAction)
        guard host.popupRequests == 1, host.popupView != nil,
              host.savedSettings?["tapCount"] as? Int == 1 else {
            fatalError("The button did not request the popup and save its setting")
        }

        (instance as? NSObject)?.perform(testAction)
        guard host.savedSettings?["tapCount"] as? Int == 41 else {
            fatalError("The plugin did not apply settings returned by the host")
        }

        instance.stop()
        (instance as? NSObject)?.perform(testAction)
        guard host.popupRequests == 2 else { fatalError("stop did not disable plugin actions") }
        print("Loaded demo bundle; configure, start, button callback, settings update, popup view, and stop passed.")
    }
}
