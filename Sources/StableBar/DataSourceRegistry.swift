import AppKit
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
    /// Notifications macOS posts when the data changes between the runner's refreshes, such as
    /// calendar's `EKEventStoreChanged`. While the source runs, the runner also refreshes it each
    /// time one is posted on `changeCenter`, with an event named after the type.
    var changeNotifications: [Notification.Name] = []
    var changeCenter: SourceChange.Center = .standard
    /// Seconds between refreshes when the provider sets no `interval`.
    var defaultInterval: Double = 5
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
                                                detail: "App menus and the Apple menu read the frontmost app's menus and open them. Control Center and Menu bar items open items in the macOS menu bar. Workspaces switches macOS desktops and reads Dock badges.",
                                                symbol: "accessibility", privacyPane: "Privacy_Accessibility")
    static let screenRecording = SourcePermission(title: "Screen Recording",
                                                  detail: "Menu bar items shown as in the menu bar are copied from it. StableBar records nothing else.",
                                                  symbol: "rectangle.dashed.badge.record", privacyPane: "Privacy_ScreenCapture")
    static let location = SourcePermission(title: "Location",
                                           detail: "Wi-Fi widgets show your network's name, which macOS shares only with apps allowed to use Location Services. macOS asks for access the first time one updates.",
                                           symbol: "location", privacyPane: "Privacy_LocationServices")
}

extension WidgetContent {
    var permissions: [SourcePermission] {
        switch self {
        case let .menuBarItems(_, _, shown, _) where shown.references.contains { $0.display == .live }: [.accessibility, .screenRecording]
        case .appMenu, .appleMenu(click: .menu), .controlCenter, .menuBarItems: [.accessibility]
        default: []
        }
    }
}

extension WidgetConfiguration {
    /// The access the widget needs: its content's, or Accessibility for Workspaces that shows Dock badges, or on
    /// macOS Spaces, which switches desktops by pressing their shortcuts. Window managers switch workspaces themselves.
    func permissions(source: WorkspaceSource) -> [SourcePermission] {
        content == .workspaces && (source == .spaces || showsDockBadges) ? [.accessibility] : content.permissions
    }

    /// Whether the widget draws its apps' Dock badges.
    var showsDockBadges: Bool {
        content == .workspaces && workspace?.badges != nil && workspace?.showApps != false
    }
}

extension Configuration {
    /// Whether a widget draws Dock badges on any screen: a screen's own look can turn them on by itself.
    var showsDockBadges: Bool {
        ([self] + screenLooks.values).contains { $0.widgets.contains { $0.enabled && $0.showsDockBadges } }
    }
}

struct DataSourceRegistry: Sendable {
    let types: [DataSourceType]

    subscript(name: String) -> DataSourceType? {
        types.first { $0.name == name }
    }

    /// The permissions that the sources a configuration runs need, in registry order, then those its
    /// enabled widgets need, each once. A screen's own look can show menu bar items live by itself.
    func permissions(for configuration: Configuration?) -> [SourcePermission] {
        guard let configuration else { return [] }
        let running = Set(configuration.activeProviders.compactMap { configuration.providers[$0]?.type })
        var listed = Set<SourcePermission>()
        return (types.filter { running.contains($0.name) }.compactMap(\.permission)
                + configuration.widgets.filter(\.enabled).flatMap { $0.permissions(source: configuration.workspaceSource) }
                + (configuration.liveMenuBarItems.isEmpty ? [] : [.accessibility, .screenRecording]))
            .filter { listed.insert($0).inserted }
    }

    static let builtIn = DataSourceRegistry(types: [.command, .stream, .battery, .bluetooth, .system, .network, .wifi, .disk, .audio, .inputSource,
                                                    .microphone, .privacy, .calendar, .merge])
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

    /// A device's charge changes over hours, so two minutes is soon enough to see one connect or run low.
    static let bluetooth = DataSourceType(name: "bluetooth", isNative: true, symbol: "dot.radiowaves.left.and.right", settings: [],
                                          continuous: false, defaultInterval: 120) { _, _ in
        PollingSource { _ in
            do {
                return .output(.success(try await Bluetooth.read()))
            } catch {
                return .output(.failure(error))
            }
        }
    }

    /// With `processes`, its output also lists the apps and processes using the most memory and CPU.
    static let system = DataSourceType(name: "system", isNative: true, symbol: "cpu", settings: [], optionalSettings: [.processes, .sortBy, .cpuWarning, .memoryWarning],
                                       continuous: false) { provider, _ in
        let metrics = NativeMetrics()
        let processes = ProcessMetrics()
        return PollingSource { _ in
            let lists = provider.processes > 0 ? await processes.lists(count: provider.processes) : nil
            return .output(Result {
                var output = try metrics.system(provider)
                output.lists = lists
                output.lists?["apps"] = lists?[provider.sortBy.rawValue]
                return output
            })
        }
    }

    static let network = DataSourceType(name: "network", isNative: true, symbol: "network", settings: [], optionalSettings: [.units], continuous: false,
                                        changeNotifications: [NetworkConnection.changedNotification]) { provider, _ in
        let metrics = NativeMetrics()
        return PollingSource { _ in
            .output(Result {
                var output = try metrics.networkRates(units: provider.units)
                output.fields!.merge(NetworkConnection.shared.fields) { $1 }
                return output
            })
        }
    }

    static let wifi = DataSourceType(name: "wifi", isNative: true, symbol: "wifi", settings: [], continuous: true,
                                     events: [.wifiChange], permission: .location) { _, _ in
        PushSource(monitor: WiFiMonitor())
    }

    static let disk = disk()

    /// How full the startup disk is, and the other volumes, read on a timer and whenever one mounts,
    /// unmounts or is renamed.
    static func disk(reader: any VolumeReading = SystemVolumes()) -> DataSourceType {
        DataSourceType(name: "disk", isNative: true, symbol: "internaldrive", settings: [],
                       optionalSettings: [.diskWarning, .diskCritical], continuous: false,
                       changeNotifications: [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                                             NSWorkspace.didRenameVolumeNotification],
                       changeCenter: .workspace, defaultInterval: 60) { provider, _ in
            PollingSource { _ in
                do {
                    let volumes = try await BlockingWork.run { try reader.read() }
                    return .output(.success(diskOutput(volumes, warning: provider.diskWarning, critical: provider.diskCritical)))
                } catch {
                    return .output(.failure(error))
                }
            }
        }
    }

    static let audio = DataSourceType(name: "audio", isNative: true, symbol: "speaker.wave.2", settings: [], continuous: true,
                                      events: [.volumeChange, .outputDeviceChange]) { _, _ in
        PushSource(monitor: AudioMonitor())
    }

    static let inputSource = DataSourceType(name: "inputSource", isNative: true, symbol: "keyboard", settings: [], continuous: true,
                                            events: [.inputSourceChange]) { _, _ in
        PushSource(monitor: InputSourceMonitor())
    }

    static let microphone = DataSourceType(name: "microphone", isNative: true, symbol: "mic", settings: [], continuous: true,
                                           events: [.microphoneChange, .inputDeviceChange]) { _, _ in
        PushSource(monitor: AudioMonitor(input: true))
    }

    static let privacy = DataSourceType(name: "privacy", isNative: true, symbol: "hand.raised", settings: [], continuous: true,
                                        events: [.privacyChange]) { _, _ in
        PushSource(monitor: PrivacyMonitor())
    }

    /// Its output sets its own `interval`, so the runner reads it again at the next minute or phase
    /// boundary.
    static let calendar = DataSourceType(name: "calendar", isNative: true, symbol: "calendar", settings: [],
                                         optionalSettings: [.calendars, .lookahead, .soon, .now], continuous: false,
                                         changeNotifications: [.EKEventStoreChanged], permission: .calendars) { provider, _ in
        let metrics = CalendarMetrics()
        return PollingSource { _ in .output(.success(await metrics.read(provider))) }
    }

    /// Combines the providers it names. The store runs it on their runners, as a `MergeSource`.
    static let merge = DataSourceType(name: "merge", isNative: false, symbol: "square.stack.3d.up", settings: [.providers],
                                      continuous: true) { _, _ in
        fatalError("The store runs a merge on the runners of its providers.")
    }
}
