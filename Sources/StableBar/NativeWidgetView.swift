import AppKit
import Foundation
import NativeWidgetPluginABI
import SwiftUI

private struct NativeWidgetExecutionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var nativeWidgetExecutionAllowed: Bool {
        get { self[NativeWidgetExecutionKey.self] }
        set { self[NativeWidgetExecutionKey.self] = newValue }
    }
}

@MainActor
struct NativeWidgetPluginSession {
    let bundle: NativePluginBundle
    let settings: [String: ConfigurationValue]
    let instance: NativeWidgetPluginInstance
}

@MainActor
protocol NativeWidgetPluginRuntime {
    func loadActivePlugin(packageID: String) async throws -> NativeWidgetPluginSession?
    func validateActivePlugin(packageID: String, expected: NativePluginBundle) async throws -> [String: ConfigurationValue]
    func saveSettings(packageID: String, expected: NativePluginBundle,
                      settings: [String: ConfigurationValue]) async throws -> [String: ConfigurationValue]
}

@MainActor
final class PackageLibraryNativeWidgetPluginRuntime: NativeWidgetPluginRuntime {
    private weak var library: PackageLibrary?
    private let packages: WidgetPackageStore

    init(library: PackageLibrary, packages: WidgetPackageStore) {
        self.library = library
        self.packages = packages
    }

    func loadActivePlugin(packageID: String) async throws -> NativeWidgetPluginSession? {
        guard let library, let bundle = try await library.activeNativePlugin(packageID: packageID) else { return nil }
        let settings = try await library.activeNativePluginSettings(packageID: packageID, version: bundle.version)
        guard try await library.activeNativePlugin(packageID: packageID) == bundle else {
            throw NativeWidgetViewError.pluginChanged
        }
        let loader = NativeWidgetPluginLoader(trustStore: NativePluginTrustStore(url: packages.nativePluginTrustURL))
        let instance = try loader.load(at: bundle.url, expectedPluginID: packageID, expectedVersion: bundle.version)
        return NativeWidgetPluginSession(bundle: bundle, settings: settings, instance: instance)
    }

    func validateActivePlugin(packageID: String, expected: NativePluginBundle) async throws -> [String: ConfigurationValue] {
        guard let library, try await library.activeNativePlugin(packageID: packageID) == expected else {
            throw NativeWidgetViewError.pluginChanged
        }
        return try await library.activeNativePluginSettings(packageID: packageID, version: expected.version)
    }

    func saveSettings(packageID: String, expected: NativePluginBundle,
                      settings: [String: ConfigurationValue]) async throws -> [String: ConfigurationValue] {
        _ = try await validateActivePlugin(packageID: packageID, expected: expected)
        guard let library else { throw NativeWidgetViewError.pluginNotActive }
        try await library.saveNativePluginSettings(packageID: packageID, version: expected.version, settings: settings)
        return try await validateActivePlugin(packageID: packageID, expected: expected)
    }
}

struct NativeWidgetView: NSViewRepresentable {
    let packageID: String
    let widget: WidgetConfiguration
    let defaults: WidgetStyle
    let popupDefaults: WidgetStyle
    let store: BarStore
    let anchor: NSView
    let packageSelections: ConfigurationValue?
    let displayID: Int

    static var isSwiftUIPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    static func shouldLoadPlugin(measuring: Bool, offline: Bool = false, executionAllowed: Bool = true,
                                 isPreview: Bool) -> Bool {
        !measuring && !offline && executionAllowed && !isPreview
    }

    @MainActor func makeCoordinator() -> Coordinator {
        let packages = WidgetPackageStore(directory: store.configurationURL.deletingLastPathComponent()
            .appending(path: "packages"))
        let runtime = PackageLibraryNativeWidgetPluginRuntime(library: store.packageLibrary, packages: packages)
        return Coordinator(packageID: packageID, widget: widget, defaults: defaults, popupDefaults: popupDefaults,
                           store: store, anchor: anchor, runtime: runtime)
    }

    @MainActor func makeNSView(context: Context) -> NativeWidgetContainerView {
        let view = NativeWidgetContainerView()
        view.widthDidChange = { [weak store] width in
            Task { @MainActor in
                guard let store, store.packageLibrary.nativeWidgetWidths[displayID]?[widget.id] != width else { return }
                store.packageLibrary.nativeWidgetWidths[displayID, default: [:]][widget.id] = width
            }
        }
        context.coordinator.attach(to: view)
        context.coordinator.startIfNeeded()
        return view
    }

    @MainActor func updateNSView(_ nsView: NativeWidgetContainerView, context: Context) {
        context.coordinator.update(defaults: defaults, popupDefaults: popupDefaults, anchor: anchor,
                                   packageSelections: packageSelections)
    }

    @MainActor static func dismantleNSView(_ nsView: NativeWidgetContainerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let packageID: String
        private let widget: WidgetConfiguration
        private let runtime: any NativeWidgetPluginRuntime
        private weak var store: BarStore?
        private weak var anchor: NSView?
        private var defaults: WidgetStyle
        private var popupDefaults: WidgetStyle
        private weak var container: NativeWidgetContainerView?
        private var pluginView: NSView?
        private var plugin: NativeWidgetPluginInstance?
        private var host: NativeWidgetPluginHost?
        private var bundle: NativePluginBundle?
        private var eventToken: UUID?
        private var loadTask: Task<Void, Never>?
        private var operationTasks: [UUID: Task<Void, Never>] = [:]
        private var settingsRefresh: Task<Void, Never>?
        private var observedSelections: ConfigurationValue?
        private var currentSettings: [String: ConfigurationValue]?
        private var stopped = false

        init(packageID: String, widget: WidgetConfiguration, defaults: WidgetStyle, popupDefaults: WidgetStyle,
             store: BarStore, anchor: NSView, runtime: any NativeWidgetPluginRuntime) {
            self.packageID = packageID
            self.widget = widget
            self.runtime = runtime
            self.defaults = defaults
            self.popupDefaults = popupDefaults
            self.store = store
            self.anchor = anchor
        }

        func attach(to container: NativeWidgetContainerView) {
            self.container = container
        }

        func update(defaults: WidgetStyle, popupDefaults: WidgetStyle, anchor: NSView,
                    packageSelections: ConfigurationValue? = nil) {
            self.defaults = defaults
            self.popupDefaults = popupDefaults
            self.anchor = anchor
            guard observedSelections != packageSelections else { return }
            observedSelections = packageSelections
            settingsRefresh?.cancel()
            settingsRefresh = Task { @MainActor [weak self] in
                guard let self, let plugin, let bundle else { return }
                do {
                    let settings = try await runtime.validateActivePlugin(packageID: packageID, expected: bundle)
                    try Task.checkCancellation()
                    guard !stopped, self.plugin === plugin, currentSettings != settings else { return }
                    currentSettings = settings
                    plugin.settingsDidChange(try NativeWidgetSettingsBridge.foundationDictionary(from: settings))
                } catch is CancellationError {} catch {
                    container?.showOperationError(error.localizedDescription)
                }
            }
        }

        func startIfNeeded() {
            guard !stopped, loadTask == nil, plugin == nil, let store else { return }
            loadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    guard let session = try await runtime.loadActivePlugin(packageID: packageID) else {
                        throw NativeWidgetViewError.pluginNotActive
                    }
                    try Task.checkCancellation()
                    guard !stopped else { return }
                    let instance = session.instance
                    let host = NativeWidgetPluginHost()
                    host.requestPopupHandler = { [weak self] in self?.requestPopup() }
                    host.saveSettingsHandler = { [weak self] settings in self?.saveSettings(settings) }
                    plugin = instance
                    bundle = session.bundle
                    self.host = host
                    eventToken = store.packageLibrary.nativeWidgetEvents.register(widgetID: widget.id) { [weak instance] name, payload in
                        instance?.sendEvent(name: name, payload: payload.mapValues { $0 as Any })
                    }
                    let foundationSettings = try NativeWidgetSettingsBridge.foundationDictionary(from: session.settings)
                    currentSettings = session.settings
                    instance.start(host: host, settings: foundationSettings)
                    try Task.checkCancellation()
                    guard let container, !stopped else {
                        instance.stop()
                        return
                    }
                    let view = instance.makeWidgetView()
                    guard view.superview == nil, view.window == nil else {
                        throw NativeWidgetViewError.viewAlreadyAttached
                    }
                    pluginView = view
                    container.install(view)
                } catch is CancellationError {
                    return
                } catch {
                    guard !stopped else { return }
                    container?.showError(error.localizedDescription)
                    stopPlugin()
                }
                loadTask = nil
            }
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            loadTask?.cancel()
            loadTask = nil
            operationTasks.values.forEach { $0.cancel() }
            operationTasks.removeAll()
            settingsRefresh?.cancel()
            settingsRefresh = nil
            if let store { store.popup.close(widgetID: widget.id) }
            stopPlugin()
            pluginView?.removeFromSuperview()
            pluginView = nil
            container?.clear()
            container = nil
            anchor = nil
            store = nil
        }

        private func stopPlugin() {
            if let eventToken, let store { store.packageLibrary.nativeWidgetEvents.unregister(eventToken) }
            eventToken = nil
            plugin?.stop()
            plugin = nil
            bundle = nil
            host?.requestPopupHandler = nil
            host?.saveSettingsHandler = nil
            host = nil
        }

        private func verifyActivePlugin() async throws -> (BarStore, NativeWidgetPluginInstance, NativePluginBundle) {
            guard !stopped, let store, let plugin, let bundle else { throw NativeWidgetViewError.pluginNotActive }
            _ = try await runtime.validateActivePlugin(packageID: packageID, expected: bundle)
            try Task.checkCancellation()
            guard !stopped, self.plugin === plugin, self.bundle == bundle else { throw NativeWidgetViewError.pluginChanged }
            return (store, plugin, bundle)
        }

        private func requestPopup() {
            guard !stopped else { return }
            performOperation { coordinator in
                do {
                    let (store, plugin, _) = try await coordinator.verifyActivePlugin()
                    guard let anchor = coordinator.anchor, anchor.window != nil, !coordinator.stopped else {
                        coordinator.container?.showOperationError("The widget is not attached to a window yet.")
                        return
                    }
                    if store.popup.toggleIfOpen(coordinator.widget.id, anchor: anchor) {
                        coordinator.container?.clearOperationError()
                        return
                    }
                    let popup = widgetPopup(coordinator.widget, store: store)
                        ?? PopupConfiguration(style: WidgetStyle(), layout: PopupBlock(content: .text("")))
                    let popupView = plugin.makePopupView()
                    guard popupView.superview == nil, popupView.window == nil else {
                        throw NativeWidgetViewError.viewAlreadyAttached
                    }
                    let opened = store.popup.open(popupView, popup: popup, widget: coordinator.widget,
                                                  defaults: coordinator.popupDefaults.inheriting(coordinator.defaults), store: store,
                                                  anchor: anchor, onHover: false)
                    if !opened { popupView.removeFromSuperview() }
                    coordinator.container?.clearOperationError()
                } catch is CancellationError {
                    return
                } catch {
                    coordinator.container?.showOperationError(error.localizedDescription)
                }
            }
        }

        private func saveSettings(_ settings: [String: Any]) {
            guard !stopped, let store else { return }
            let previous = store.packageLibrary.nativeWidgetSaveTails[packageID]
            let task = performOperation(after: previous) { coordinator in
                do {
                    let (_, plugin, bundle) = try await coordinator.verifyActivePlugin()
                    let values = try NativeWidgetSettingsBridge.configurationValues(from: settings)
                    let updated = try await coordinator.runtime.saveSettings(packageID: coordinator.packageID,
                                                                            expected: bundle, settings: values)
                    try Task.checkCancellation()
                    guard !coordinator.stopped, coordinator.plugin === plugin, coordinator.bundle == bundle else { return }
                    coordinator.currentSettings = updated
                    plugin.settingsDidChange(try NativeWidgetSettingsBridge.foundationDictionary(from: updated))
                    coordinator.container?.clearOperationError()
                } catch is CancellationError {
                    return
                } catch {
                    coordinator.container?.showOperationError(error.localizedDescription)
                }
            }
            store.packageLibrary.nativeWidgetSaveTails[packageID] = task
        }

        @discardableResult
        private func performOperation(after previous: Task<Void, Never>? = nil,
                                      _ operation: @escaping @MainActor (Coordinator) async -> Void) -> Task<Void, Never>? {
            guard !stopped else { return nil }
            let id = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { operationTasks.removeValue(forKey: id) }
                await previous?.value
                guard !Task.isCancelled else { return }
                await operation(self)
            }
            operationTasks[id] = task
            return task
        }
    }
}

@MainActor
final class NativeWidgetContainerView: NSView {
    private var contentView: NSView?
    private var errorView: NSImageView?
    var widthDidChange: ((CGFloat) -> Void)?

    override func layout() {
        super.layout()
        reportWidth()
    }

    private func reportWidth() {
        guard let width = contentView?.fittingSize.width, width.isFinite, width > 0 else { return }
        widthDidChange?(width)
    }

    override var intrinsicContentSize: NSSize {
        contentView?.intrinsicContentSize ?? NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func install(_ view: NSView) {
        clear()
        contentView = view
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        invalidateIntrinsicContentSize()
        reportWidth()
    }

    func showError(_ message: String) {
        clear()
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Native widget unavailable")
        image.imageScaling = .scaleProportionallyDown
        image.toolTip = message
        image.setAccessibilityLabel("Native widget unavailable")
        image.frame = bounds
        image.autoresizingMask = [.width, .height]
        errorView = image
        addSubview(image)
    }

    func showOperationError(_ message: String) {
        toolTip = message
        contentView?.toolTip = message
        contentView?.setAccessibilityHelp(message)
    }

    func clearOperationError() {
        toolTip = nil
        contentView?.toolTip = nil
        contentView?.setAccessibilityHelp(nil)
    }

    func clear() {
        contentView?.removeFromSuperview()
        contentView = nil
        errorView?.removeFromSuperview()
        errorView = nil
        invalidateIntrinsicContentSize()
    }
}

@MainActor
private final class NativeWidgetPluginHost: NSObject, StableBarNativeWidgetHost {
    var requestPopupHandler: (() -> Void)?
    var saveSettingsHandler: (([String: Any]) -> Void)?

    func requestPopup() { requestPopupHandler?() }
    func saveSettings(_ settings: [String: Any]) { saveSettingsHandler?(settings) }
}

enum NativeWidgetSettingsBridgeError: Error, Equatable {
    case invalidSettings
}

enum NativeWidgetSettingsBridge {
    static func foundationDictionary(from values: [String: ConfigurationValue]) throws -> [String: Any] {
        do {
            let data = try JSONEncoder().encode(values)
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NativeWidgetSettingsBridgeError.invalidSettings
            }
            return dictionary
        } catch {
            throw NativeWidgetSettingsBridgeError.invalidSettings
        }
    }

    static func configurationValues(from settings: [String: Any]) throws -> [String: ConfigurationValue] {
        do {
            guard JSONSerialization.isValidJSONObject(settings) else {
                throw NativeWidgetSettingsBridgeError.invalidSettings
            }
            let data = try JSONSerialization.data(withJSONObject: settings)
            return try JSONDecoder().decode([String: ConfigurationValue].self, from: data)
        } catch {
            throw NativeWidgetSettingsBridgeError.invalidSettings
        }
    }
}

private enum NativeWidgetViewError: LocalizedError {
    case pluginNotActive
    case pluginChanged
    case viewAlreadyAttached

    var errorDescription: String? {
        switch self {
        case .pluginNotActive: "The native widget package is disabled or unavailable."
        case .pluginChanged: "The installed native widget changed. Reopen the bar to load it again."
        case .viewAlreadyAttached: "The native widget returned a view that is already in use."
        }
    }
}
