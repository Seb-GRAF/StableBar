import AppKit
import Foundation
import NativeWidgetPluginABI
import Testing
@testable import StableBar

@Test func nativeWidgetSettingsBridgePreservesJSONValuesAndRejectsNonJSONValues() throws {
    let settings: [String: ConfigurationValue] = [
        "title": .string("Status"),
        "count": .number(3),
        "enabled": .bool(true),
        "nested": .object(["values": .array([.string("one"), .null])])
    ]

    let dictionary = try NativeWidgetSettingsBridge.foundationDictionary(from: settings)
    #expect(try NativeWidgetSettingsBridge.configurationValues(from: dictionary) == settings)

    #expect(throws: NativeWidgetSettingsBridgeError.invalidSettings) {
        try NativeWidgetSettingsBridge.configurationValues(from: ["unsupported": Date()])
    }
}

@Test @MainActor func nativeWidgetLoadPolicySkipsMeasurementAndSwiftUIPreviews() {
    #expect(!NativeWidgetView.shouldLoadPlugin(measuring: true, isPreview: false))
    #expect(!NativeWidgetView.shouldLoadPlugin(measuring: false, offline: true, isPreview: false))
    #expect(!NativeWidgetView.shouldLoadPlugin(measuring: false, executionAllowed: false, isPreview: false))
    #expect(!NativeWidgetView.shouldLoadPlugin(measuring: false, isPreview: true))
    #expect(NativeWidgetView.shouldLoadPlugin(measuring: false, isPreview: false))
}

@MainActor
private final class NativeWidgetLifecyclePlugin: NSObject, StableBarNativeWidgetPlugin {
    let widgetView = NSView()
    let popupView = NSView()
    var host: (any StableBarNativeWidgetHost)?
    var startCount = 0
    var stopCount = 0
    var receivedEvent: (String, [String: Any])?
    var changedSettings: [String: Any]?

    var apiVersion: Int { 1 }
    func makeWidgetView() -> NSView { widgetView }
    func makePopupView() -> NSView { popupView }
    func configure(with host: any StableBarNativeWidgetHost, settings: [String: Any]) { self.host = host }
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func settingsDidChange(_ settings: [String: Any]) { changedSettings = settings }
    func stableBarDidReceiveEvent(_ name: String, payload: [String: Any]) { receivedEvent = (name, payload) }
}

@MainActor
private final class NativeWidgetRuntimeFixture: NativeWidgetPluginRuntime {
    let session: NativeWidgetPluginSession
    var validationCount = 0
    var savedSettings: [String: ConfigurationValue]?
    var validationError: Error?
    var pauseNextSave = false
    var saveInProgress = false
    private var saveContinuation: CheckedContinuation<Void, Never>?

    init(session: NativeWidgetPluginSession) { self.session = session }

    func loadActivePlugin(packageID: String) async throws -> NativeWidgetPluginSession? { session }

    func validateActivePlugin(packageID: String, expected: NativePluginBundle) async throws -> [String: ConfigurationValue] {
        validationCount += 1
        if let validationError { throw validationError }
        return session.settings
    }

    func saveSettings(packageID: String, expected: NativePluginBundle,
                      settings: [String: ConfigurationValue]) async throws -> [String: ConfigurationValue] {
        if pauseNextSave {
            pauseNextSave = false
            saveInProgress = true
            await withCheckedContinuation { saveContinuation = $0 }
            saveInProgress = false
        }
        savedSettings = settings
        return settings
    }

    func resumeSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }
}

@Test @MainActor func nativeWidgetCoordinatorStartsHostsCallbacksAndStopsItsPlugin() async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"native","type":"nativePlugin","plugin":"native","position":"right"}]}
    """#.utf8))
    var panels: [PopupPanel] = []
    let popup = WidgetPopup(present: { panel, _ in panels.append(panel) })
    let configurationURL = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    let store = BarStore(configurationURL: configurationURL, popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop(); try? FileManager.default.removeItem(at: configurationURL) }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600,
                           sharedStore: store)
    defer { bar.close() }
    await bar.settle()

    let widget = configuration.widgets[0]
    let anchor = try #require(bar.anchors(widget.id).first)
    let plugin = NativeWidgetLifecyclePlugin()
    let bundle = NativePluginBundle(packageID: "native", version: "1.0.0", path: "Native.bundle",
                                    url: Bundle.main.bundleURL, bundleID: "com.example.native", apiMajor: 1,
                                    signature: NativePluginSignature(identifier: "com.example.native",
                                                                     teamIdentifier: "TEAM", cdhash: "cdhash"))
    let instance = NativeWidgetPluginInstance(bundle: .main, plugin: plugin)
    let runtime = NativeWidgetRuntimeFixture(session: NativeWidgetPluginSession(
        bundle: bundle, settings: ["title": .string("Native")], instance: instance))
    let coordinator = NativeWidgetView.Coordinator(packageID: "native", widget: widget, defaults: configuration.defaults,
                                                   popupDefaults: configuration.defaults, store: store, anchor: anchor,
                                                   runtime: runtime)
    let container = NativeWidgetContainerView()
    coordinator.attach(to: container)
    coordinator.startIfNeeded()
    for _ in 0..<100 where plugin.startCount == 0 { try await Task.sleep(for: .milliseconds(10)) }

    #expect(plugin.startCount == 1)
    #expect(plugin.widgetView.superview === container)
    #expect(plugin.host != nil)

    store.packageLibrary.nativeWidgetEvents.send("widget.ready", environment: ["source": "test"], to: [widget.id])
    #expect(plugin.receivedEvent?.0 == "widget.ready")
    #expect(plugin.receivedEvent?.1["source"] as? String == "test")

    runtime.validationError = CocoaError(.userCancelled)
    plugin.host?.requestPopup()
    for _ in 0..<100 where container.toolTip == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(container.toolTip != nil)
    #expect(plugin.widgetView.superview === container)
    #expect(plugin.stopCount == 0)

    runtime.validationError = nil
    plugin.host?.requestPopup()
    for _ in 0..<100 where !popup.isOpen { try await Task.sleep(for: .milliseconds(10)) }
    #expect(popup.isOpen)
    #expect(runtime.validationCount > 0)
    #expect(panels.count == 1)

    plugin.host?.saveSettings(["unsupported": Date()])
    for _ in 0..<100 where container.toolTip == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(plugin.widgetView.superview === container)
    #expect(plugin.stopCount == 0)

    plugin.host?.saveSettings(["title": "Changed"])
    for _ in 0..<100 where runtime.savedSettings == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(runtime.savedSettings == ["title": .string("Changed")])
    #expect(plugin.changedSettings?["title"] as? String == "Changed")

    plugin.changedSettings = nil
    runtime.pauseNextSave = true
    plugin.host?.saveSettings(["title": "Late"])
    for _ in 0..<100 where !runtime.saveInProgress { try await Task.sleep(for: .milliseconds(10)) }
    #expect(runtime.saveInProgress)
    coordinator.stop()
    runtime.resumeSave()
    for _ in 0..<20 where runtime.saveInProgress { try await Task.sleep(for: .milliseconds(10)) }
    #expect(plugin.stopCount == 1)
    #expect(plugin.widgetView.superview == nil)
    #expect(!popup.isOpen)
    #expect(plugin.changedSettings == nil)
    store.packageLibrary.nativeWidgetEvents.send("after.stop", environment: [:], to: [widget.id])
    #expect(plugin.receivedEvent?.0 == "widget.ready")
}
