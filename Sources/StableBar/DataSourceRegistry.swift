import EventKit
import Foundation

/// A kind of data source that providers name in `type`: the settings it reads, how StableBar runs
/// it, the events it sends and the access it needs. Adding a source means adding one entry to
/// `DataSourceRegistry.builtIn`.
struct DataSourceType: Sendable {
    /// The `type` name in provider definitions, such as `battery`.
    var name: String
    /// Whether a widget can name this type directly, sharing a default provider of that name.
    /// `command` and `stream` need a `command`, so widgets reach them through `providers`.
    var isNative: Bool
    /// The SF Symbol the editor shows for widgets of this type.
    var symbol: String
    /// Provider properties this type requires besides the ones every provider has: `type`,
    /// `interval`, `timeout`, `environment`, `whenVisible` and `events`.
    var settings: [ProviderConfiguration.CodingKeys]
    /// Provider properties this type reads when they are set and otherwise gives a default, such as
    /// calendar's `lookahead`. The decoder accepts them on every type; other types ignore them.
    var optionalSettings: [ProviderConfiguration.CodingKeys] = []
    /// Whether runs stay open and the source sends updates as they happen, like a stream or a native
    /// listener; otherwise the runner refreshes it every `interval`.
    var continuous: Bool
    /// The built-in events this source sends when its output changes.
    var events: [BuiltInEvent] = []
    /// A notification macOS posts when the data changes between the runner's refreshes, such as
    /// calendar's `EKEventStoreChanged`. While the source runs, the runner also refreshes it each
    /// time it's posted, with an event named after the type.
    var changeNotification: Notification.Name? = nil
    /// The access the source needs. Setup lists it whenever a configuration runs this source. The
    /// source asks macOS for it the first time it reads, and until it's granted, its output says so
    /// rather than failing, as calendar's `No calendar access` with `fields.access` does.
    var permission: SourcePermission? = nil
    /// Creates the source for one provider definition, with the provider's environment.
    var makeSource: @MainActor @Sendable (ProviderConfiguration, [String: String]) -> any DataSource
}

/// Access that a data source needs before it can read its data, such as Calendars.
struct SourcePermission: Hashable, Sendable {
    /// What setup calls it, such as `Calendars`.
    let title: String
    /// Why widgets need it.
    let detail: String
    /// The SF Symbol setup shows beside it.
    let symbol: String
    /// The Privacy & Security pane that grants it, such as `Privacy_Calendars`.
    let privacyPane: String
}

extension SourcePermission {
    static let calendars = SourcePermission(title: "Calendars",
                                            detail: "Calendar widgets show your next meeting and today's agenda. macOS asks for access the first time one updates.",
                                            symbol: "calendar", privacyPane: "Privacy_Calendars")
    static let accessibility = SourcePermission(title: "Accessibility",
                                                detail: "App menus and the Apple menu read the frontmost app's menus and open them.",
                                                symbol: "accessibility", privacyPane: "Privacy_Accessibility")
}

extension WidgetContent {
    var permissions: [SourcePermission] {
        switch self {
        case .appMenu, .appleMenu: [.accessibility]
        default: []
        }
    }
}

struct DataSourceRegistry: Sendable {
    let types: [DataSourceType]

    subscript(name: String) -> DataSourceType? {
        types.first { $0.name == name }
    }

    /// The permissions that the sources a configuration runs need, in registry order, then those its
    /// enabled widgets need, each once.
    func permissions(for configuration: Configuration?) -> [SourcePermission] {
        guard let configuration else { return [] }
        let running = Set(configuration.activeProviders.compactMap { configuration.providers[$0]?.type })
        var listed = Set<SourcePermission>()
        return (types.filter { running.contains($0.name) }.compactMap(\.permission)
                + configuration.widgets.filter(\.enabled).flatMap(\.content.permissions)).filter { listed.insert($0).inserted }
    }

    static let builtIn = DataSourceRegistry(types: [.command, .stream, .battery, .system, .network, .audio, .calendar])
}

extension DataSourceType {
    static let command = DataSourceType(name: "command", isNative: false, symbol: "terminal", settings: [.command],
                                        continuous: false) { provider, environment in
        PollingSource.command(provider.command!, timeout: provider.timeout, environment: environment)
    }

    static let stream = DataSourceType(name: "stream", isNative: false, symbol: "terminal", settings: [.command],
                                       continuous: true) { provider, environment in
        StreamSource(command: provider.command!, environment: environment)
    }

    static let battery = DataSourceType(name: "battery", isNative: true, symbol: "battery.100percent", settings: [],
                                        continuous: true, events: [.powerSourceChange]) { _, _ in
        PushSource(monitor: PowerMonitor())
    }

    static let system = DataSourceType(name: "system", isNative: true, symbol: "cpu", settings: [], continuous: false) { _, _ in
        let metrics = NativeMetrics()
        return PollingSource { _ in .output(Result { try metrics.system() }) }
    }

    static let network = DataSourceType(name: "network", isNative: true, symbol: "network", settings: [], continuous: false) { _, _ in
        let metrics = NativeMetrics()
        return PollingSource { _ in .output(Result { try metrics.networkRates() }) }
    }

    static let audio = DataSourceType(name: "audio", isNative: true, symbol: "speaker.wave.2", settings: [], continuous: true,
                                      events: [.volumeChange, .outputDeviceChange]) { _, _ in
        PushSource(monitor: AudioMonitor())
    }

    /// Its output sets its own `interval`, so the runner reads it again at the next minute or phase
    /// boundary.
    static let calendar = DataSourceType(name: "calendar", isNative: true, symbol: "calendar", settings: [],
                                         optionalSettings: [.calendars, .lookahead, .soon, .now], continuous: false,
                                         changeNotification: .EKEventStoreChanged, permission: .calendars) { provider, _ in
        let metrics = CalendarMetrics()
        return PollingSource { _ in .output(.success(await metrics.read(provider))) }
    }
}
