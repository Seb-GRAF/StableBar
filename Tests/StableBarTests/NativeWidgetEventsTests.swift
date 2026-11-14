import Foundation
import Testing
@testable import StableBar

@Test @MainActor func nativeWidgetEventsReachOnlySubscribedWidgetsAndStopAfterRemoval() {
    let events = NativeWidgetEvents()
    var received: [String] = []
    let first = events.register(widgetID: "first") { name, values in received.append("\(name):\(values["INFO"] ?? "")") }
    _ = events.register(widgetID: "second") { _, _ in Issue.record("Unsubscribed widget received an event") }
    events.send("changed", environment: ["INFO": "value"], to: ["first"])
    events.unregister(first)
    events.send("changed", environment: [:], to: ["first"])
    #expect(received == ["changed:value"])
}

@Test @MainActor func barStoreForwardsOnlyEventsNamedByEnabledNativeWidgets() throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"{"widgets":[{"id":"first","type":"nativePlugin","plugin":"org.example.plugin","position":"right","events":["changed"]},{"id":"disabled","type":"nativePlugin","plugin":"org.example.plugin","position":"right","enabled":false,"events":["changed"]}]}"#.utf8))
    let store = BarStore()
    store.configuration = configuration
    var received: [String] = []
    _ = store.packageLibrary.nativeWidgetEvents.register(widgetID: "first") { event, _ in received.append(event) }
    _ = store.packageLibrary.nativeWidgetEvents.register(widgetID: "disabled") { _, _ in Issue.record("Disabled widget received an event") }
    store.refreshScripts(for: "other")
    store.refreshScripts(for: "changed")
    #expect(received == ["changed"])
}
