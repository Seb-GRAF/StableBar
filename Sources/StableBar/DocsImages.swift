import AppKit
import SwiftUI

/// Draws the images in docs/images from the real bar, popup and Settings views, in the dark and
/// light appearance. Sample data, a fixed date in UTC and a local, empty Store index give the same
/// pixels on every run until the views change. `scripts/render-docs-images.sh` runs it and converts
/// the images to WebP.
@MainActor
enum DocsImages {
    /// Thursday 22 October 2026, 09:41 UTC, the time the bar's sample clock shows: what every clock in a
    /// render draws instead of the current time.
    static let date = Date(timeIntervalSince1970: 1_792_662_060)

    /// Draws times in UTC, so a render shows the same clock on every Mac.
    static func useUTC() {
        setenv("TZ", "UTC", 1)
        NSTimeZone.resetSystemTimeZone()
    }

    /// Points the store's Store client at a local, empty index in `directory`, so the theme gallery,
    /// the widget catalog and Packages never reach the network while a render draws them.
    static func offline(_ store: BarStore, in directory: URL) throws {
        let index = directory.appending(path: "index.json")
        try Data(#"{"packages":[]}"#.utf8).write(to: index)
        store.packageStoreClient = PackageStoreClient(packages: WidgetPackageStore(directory: directory.appending(path: "packages")),
                                                      indexURL: index)
    }

    static func render(to directory: URL) async throws {
        useUTC()
        let samples = FileManager.default.temporaryDirectory.appending(path: "stablebar-docs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: samples) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for appearance in ["dark", "light"] {
            let dark = appearance == "dark"
            func store(_ name: String, theme: String?, widgets: [[String: ConfigurationValue]] = barWidgets) throws -> BarStore {
                try sampleStore(in: samples.appending(path: "\(name)-\(appearance)"), theme: theme, dark: dark, widgets: widgets)
            }
            func save(_ content: some View, _ name: String, size: NSSize, stores: [BarStore], ready: () -> Bool = { true }) async throws {
                try await snapshot(content, size: size, dark: dark, stores: stores, ready: ready,
                                   to: directory.appending(path: "\(name)-\(appearance).png"))
            }

            let bar = try store("bar", theme: "catppuccin")
            try await save(hero(bar).background { backdrop(dark: dark) }, "hero", size: NSSize(width: 1100, height: 270), stores: [bar])

            let themes = try ThemeCatalog(packages: samples.appending(path: "packages")).choices.map { choice in
                (choice.manifest.name, try store(choice.manifest.id, theme: choice.isBuiltIn ? nil : choice.manifest.id))
            }
            try await save(gallery(themes, dark: dark).background { backdrop(dark: dark) }, "themes",
                           size: NSSize(width: 1100, height: 78 * CGFloat(themes.count) + 10), stores: themes.map(\.1))
            themes.forEach { $0.1.stop() }

            let controls = try store("controls", theme: "catppuccin", widgets: barWidgets + [controlsWidget])
            let popups = HStack(alignment: .top, spacing: 24) {
                popup(controls, "system-monitor")
                popup(controls, "meeting")
                popup(controls, "controls")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            try await save(popups.background { backdrop(dark: dark) }, "popups", size: NSSize(width: 1100, height: 330), stores: [controls])
            controls.stop()

            let essentials = try sampleStore(in: samples.appending(path: "essentials-\(appearance)"), theme: nil, dark: dark,
                                             widgets: ["clock", "battery", "system", "network", "calendar"].map { type in
                WidgetAddCatalog.builtIns.first { $0.id == type }!.add(position: .right, id: type)!.properties!
            }, native: true)
            let details = VStack(alignment: .leading, spacing: 20) {
                self.bar(essentials)
                HStack(alignment: .top, spacing: 18) {
                    ForEach(["clock", "battery", "network"], id: \.self) { id in essentialsPopup(essentials, id) }
                }
                HStack(alignment: .top, spacing: 18) {
                    ForEach(["system", "calendar"], id: \.self) { id in essentialsPopup(essentials, id) }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            try await save(details.background { backdrop(dark: dark) }, "essentials", size: NSSize(width: 1100, height: 1050), stores: [essentials])
            essentials.showScreenSetup(ScreenSetup([display]))
            let essentialsEditor = ConfigurationEditor(store: essentials)
            essentialsEditor.showWidget("system")
            essentialsEditor.widgetTab = .content
            try await save(SettingsView(store: essentials, editor: essentialsEditor).background(Color(nsColor: .windowBackgroundColor)),
                           "essentials-settings", size: NSSize(width: 1080, height: 760), stores: [essentials])
            essentialsEditor.showWidget("clock")
            essentialsEditor.widgetTab = .content
            try await save(SettingsView(store: essentials, editor: essentialsEditor).background(Color(nsColor: .windowBackgroundColor)),
                           "essentials-clock-settings", size: NSSize(width: 1080, height: 760), stores: [essentials])
            essentials.stop()

            bar.showScreenSetup(ScreenSetup([display]))
            let editor = ConfigurationEditor(store: bar)
            editor.section = .appearance
            try await save(SettingsView(store: bar, editor: editor).background(Color(nsColor: .windowBackgroundColor)), "settings",
                           size: NSSize(width: 1080, height: 760), stores: [bar]) {
                !editor.gallery.choices.isEmpty && editor.gallery.choices.allSatisfy { editor.gallery.previews[$0.key] != nil }
            }
            bar.stop()
        }
    }

    private static let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
    private static let darkBackdrop = NSImage(contentsOf: Bundle.main.url(forResource: "SetupAmberDark", withExtension: "heic")!)!

    private static func backdrop(dark: Bool) -> some View {
        Image(nsImage: dark ? darkBackdrop : Wallpaper.image!).resizable().scaledToFill()
    }

    private static func bar(_ store: BarStore) -> some View {
        BarView(store: store, display: display)
            .frame(height: store.configuration!.barGeometry(for: display).panelHeight)
            .environment(\.screenKind, .monitor)
    }

    /// The bar with the meeting's agenda open below it, centered under the widget as `WidgetPopup` places it.
    private static func hero(_ store: BarStore) -> some View {
        let configuration = store.configuration!
        let popupTop = configuration.barGeometry(for: display).drawingBottom
            + configuration.look(on: .monitor).widgets.first { $0.id == "meeting" }!.popup!.offset
        return bar(store)
            .overlayPreferenceValue(BarAnchorPreference.self) { anchors in
                GeometryReader { proxy in
                    if let meeting = anchors.widgets["meeting"] {
                        let frame = proxy[meeting.bounds]
                        popup(store, "meeting").frame(width: 0).offset(x: frame.midX, y: popupTop)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private static func gallery(_ themes: [(String, BarStore)], dark: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(themes, id: \.0) { name, store in
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(dark ? Color.white.opacity(0.72) : Color.black.opacity(0.55))
                        .padding(.leading, 16)
                    bar(store)
                }
                .frame(height: 78, alignment: .top)
            }
        }
        .padding(.top, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private static func popup(_ store: BarStore, _ id: String) -> some View {
        let configuration = store.configuration!.look(on: .monitor)
        let widget = configuration.widgets.first { $0.id == id }!
        let popup = widget.popup!
        let style = popup.baseStyle(widget: widget, defaults: configuration.popupDefaults.inheriting(configuration.defaults))
        return PopupView(popup: popup, style: style, store: store, widget: widget)
            .environment(\.screenKind, .monitor)
            .frame(width: CGFloat(popup.style.width ?? 360))
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    @ViewBuilder private static func essentialsPopup(_ store: BarStore, _ id: String) -> some View {
        let configuration = store.configuration!
        let widget = configuration.widgets.first { $0.id == id }!
        let popup = widgetPopup(widget, store: store)!
        VStack(alignment: .leading, spacing: 8) {
            Text(WidgetDisplayName.title(for: widget.content, providers: configuration.providers)).font(.system(size: 12, weight: .semibold))
            PopupView(popup: popup, style: popup.baseStyle(widget: widget, defaults: configuration.popupDefaults.inheriting(configuration.defaults)),
                      store: store, widget: widget)
                .frame(width: popup.style.width!)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A bar whose data comes from sample files, with Finder as the active app. Its workspaces come
    /// from a stand-in for AeroSpace, so the bar never reaches the AeroSpace running on this Mac, and
    /// its battery from a stand-in for the Mac's, so it draws as a battery provider does.
    private static func sampleStore(in directory: URL, theme: String?, dark: Bool,
                                    widgets: [[String: ConfigurationValue]], native: Bool = false) throws -> BarStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, json) in sampleOutput { try Data(json.utf8).write(to: directory.appending(path: "\(name).json")) }
        let aerospace = directory.appending(path: "aerospace")
        try Data("""
        #!/bin/sh
        case "$1" in
        subscribe) exec /bin/sleep 600 ;;
        list-workspaces) exec /bin/cat "${0%/*}/workspaces.json" ;;
        list-windows) exec /bin/cat "${0%/*}/windows.json" ;;
        esac
        """.utf8).write(to: aerospace)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: aerospace.path)
        var configuration: [String: ConfigurationValue] = [
            "bar": .object(["offset": .number(0), "appearance": .string(dark ? "dark" : "light")]),
            "providers": .object(Dictionary(uniqueKeysWithValues: ["system", "calendar"].map { name in
                (name, .object(["type": .string("command"), "command": .string("/bin/cat \"$CONFIG_DIR/\(name).json\""),
                                "interval": .number(3600)]))
            })),
            "widgets": .array(widgets.map(ConfigurationValue.object))
        ]
        if native { configuration["providers"] = nil }
        if let theme { configuration["theme"] = .object(["id": .string(theme)]) }
        let url = directory.appending(path: "config.json")
        try JSONEncoder().encode(configuration).write(to: url)
        let battery = try ScriptOutput.read(Data(sampleOutput["battery"]!.utf8))
        let registry = DataSourceRegistry(types: DataSourceRegistry.builtIn.types.map { type in
            var type = type
            if type.name == DataSourceType.battery.name { type.makeSource = { _, _ in PushSource(monitor: SampleBattery(output: battery)) } }
            if native, let json = sampleOutput[type.name] {
                let output = try! ScriptOutput.read(Data(json.utf8))
                type.makeSource = { _, _ in PushSource(monitor: SampleBattery(output: output)) }
            }
            return type
        })
        let store = BarStore(configurationURL: url, registry: registry)
        try offline(store, in: directory)
        store.workspaceStore.executablePath = { aerospace.path }
        store.reloadConfiguration()
        store.activeApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        return store
    }

    /// Waits for the sample workspaces, every sample command's output and `ready`, adds the CPU
    /// history they can't supply and lets the views settle, then draws the content at twice its size
    /// in an offscreen window below the desktop icons.
    private static func snapshot(_ content: some View, size: NSSize, dark: Bool, stores: [BarStore], ready: () -> Bool,
                                 to url: URL) async throws {
        let view = NSHostingView(rootView: content
            .environment(\.fixedDate, date)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.14))))
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -9000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        window.orderFrontRegardless()
        while !ready() || stores.contains(where: { ($0.configuration!.widgets.contains { $0.content == .workspaces } && $0.workspaceStore.workspaces.isEmpty) || $0.scripts.values.contains { $0.outputNumber == 0 } }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        for store in stores {
            store.scripts["system-monitor"]?.samples = cpuHistory
            store.scripts["system"]?.samples = cpuHistory
        }
        try await Task.sleep(for: .seconds(3))
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        image.size = size
        view.cacheDisplay(in: view.bounds, to: image)
        try image.representation(using: .png, properties: [:])!.write(to: url)
        window.orderOut(nil)
    }

    private static let cpuHistory: [Double] = (0..<60).map { index in
        let t = Double(index)
        return 0.2 + 0.1 * sin(t / 4) + 0.07 * sin(t / 1.3) + ((41...46).contains(index) ? 0.25 : 0)
    }

    private static let sampleOutput = [
        "workspaces": #"""
        [{"workspace":"1","workspace-is-focused":false,"workspace-is-visible":false,"monitor-appkit-nsscreen-screens-id":1},
         {"workspace":"2","workspace-is-focused":true,"workspace-is-visible":true,"monitor-appkit-nsscreen-screens-id":1},
         {"workspace":"3","workspace-is-focused":false,"workspace-is-visible":false,"monitor-appkit-nsscreen-screens-id":1},
         {"workspace":"4","workspace-is-focused":false,"workspace-is-visible":false,"monitor-appkit-nsscreen-screens-id":1}]
        """#,
        "windows": #"""
        [{"workspace":"1","app-name":"Safari","app-bundle-id":"com.apple.Safari","window-id":1,"window-title":"Safari"},
         {"workspace":"2","app-name":"Xcode","app-bundle-id":"com.apple.dt.Xcode","window-id":2,"window-title":"StableBar"},
         {"workspace":"2","app-name":"Terminal","app-bundle-id":"com.apple.Terminal","window-id":3,"window-title":"zsh"},
         {"workspace":"3","app-name":"Mail","app-bundle-id":"com.apple.mail","window-id":4,"window-title":"Inbox"},
         {"workspace":"3","app-name":"Calendar","app-bundle-id":"com.apple.iCal","window-id":5,"window-title":"Calendar"},
         {"workspace":"4","app-name":"Music","app-bundle-id":"com.apple.Music","window-id":6,"window-title":"Music"}]
        """#,
        "system": #"""
        {"text":"18%","icon":"cpu","value":0.18,
         "fields":{"cpu":"18","cpuUser":"12","cpuSystem":"6","memory":"54","memoryUsed":"17.3 GB","memoryCompressed":"1.2 GB",
                   "swap":"256 MB","pressure":"normal","thermal":"nominal","load":"1.62 1.80 1.74","uptime":"2d 4h"},
         "values":{"cpu":0.18,"memory":0.54},
         "lists":{"apps":[{"name":"Xcode","pid":"100","path":"/Applications/Xcode.app","memory":"2.1 GB","cpu":"12"},
                          {"name":"Safari","pid":"101","path":"/Applications/Safari.app","memory":"840 MB","cpu":"4"},
                          {"name":"Finder","pid":"102","path":"/System/Library/CoreServices/Finder.app","memory":"120 MB","cpu":"1"}]}}
        """#,
        "network": #"{"text":"↓1.2 MiB/s ↑240 KiB/s","icon":"network","fields":{"interface":"en0","downloadRate":"1.2 MiB/s","uploadRate":"240 KiB/s"},"lists":{"interfaces":[{"name":"en0","downloadRate":"1.2 MiB/s","uploadRate":"240 KiB/s"}]},"values":{"download":1258291,"upload":245760}}"#,
        "battery": #"""
        {"text":"82%","icon":"battery.75percent","values":{"percent":0.82},
         "fields":{"percent":"82","state":"battery","present":"true","health":"normal","timeRemaining":"285"}}
        """#,
        "calendar": #"""
        {"text":"Design review","icon":"calendar",
         "fields":{"access":"granted","phase":"soon","title":"Design review","start":"10:30","end":"11:15","minutes":"12"},
         "lists":{"today":[{"title":"Standup","start":"09:15","end":"09:30"},{"title":"Design review","start":"10:30","end":"11:15"},
         {"title":"Lunch with Ana","start":"12:30","end":"13:30"},{"title":"1:1 with Sam","start":"15:00","end":"15:30"},
         {"title":"Release planning","start":"16:30","end":"17:15"}]}}
        """#,
        "controls": #"""
        {"text":"balanced · 35%","fields":{"enabled":"true","mode":"balanced"},"values":{"level":0.35},
         "lists":{"apps":[{"name":"Finder"},{"name":"Calendar"},{"name":"Activity Monitor"},{"name":"Terminal"}]}}
        """#
    ]

    /// The widgets setup adds, between an Apple logo, the active app, the battery and the time as fixed text.
    private static let barWidgets: [[String: ConfigurationValue]] =
        widgets(#"[{ "id": "apple", "type": "text", "position": "left", "text": "", "icon": "apple.logo" }]"#)
        + SetupPreferences.WidgetSet.workspaces(.aerospace).widgets
        + widgets(#"[{ "id": "active-app", "type": "activeApp", "position": "left" }]"#)
        + SetupPreferences.WidgetSet.meetings.widgets + SetupPreferences.WidgetSet.system.widgets
        + widgets(#"""
        [
          { "id": "battery", "type": "battery", "position": "right" },
          { "id": "clock", "type": "text", "position": "right", "text": "Thu 22 Oct  09:41" }
        ]
        """#)

    /// A popup with the controls from examples/interactive.
    private static let controlsWidget = widgets(#"""
    [{
      "id": "controls", "type": "script", "position": "right", "interval": 3600, "command": "/bin/cat \"$CONFIG_DIR/controls.json\"",
      "popup": {
        "dismissOnAction": false,
        "style": { "width": 300 },
        "layout": {
          "type": "column",
          "children": [
            { "type": "text", "text": "Controls", "role": "heading" },
            { "type": "slider", "title": "Level", "source": "level", "onChange": "true" },
            { "type": "toggle", "title": "Enabled", "source": "enabled", "onChange": "true" },
            {
              "type": "segmented", "title": "Mode", "source": "mode", "onChange": "true",
              "options": [{ "title": "Quiet", "value": "quiet" }, { "title": "Balanced", "value": "balanced" }, { "title": "Focus", "value": "focus" }]
            },
            { "type": "divider", "role": "separator" },
            {
              "type": "search", "title": "Find an app", "source": "apps", "searchFields": ["name"],
              "row": { "type": "field", "field": "name", "role": "primary" }
            }
          ]
        }
      }
    }]
    """#)[0]

    private static func widgets(_ json: String) -> [[String: ConfigurationValue]] {
        try! JSONDecoder().decode([[String: ConfigurationValue]].self, from: Data(json.utf8))
    }
}

/// A battery that always reads the same sample and never changes.
private final class SampleBattery: ChangeMonitor {
    let output: ScriptOutput

    init(output: ScriptOutput) {
        self.output = output
    }

    func read() throws -> ScriptOutput { output }
    func start(changed: @escaping @Sendable () -> Void) throws {}
    func stop() {}
}
