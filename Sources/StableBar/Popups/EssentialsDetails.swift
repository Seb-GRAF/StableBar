import SwiftUI

enum EssentialsPopup: String, Sendable {
    case clock, battery, system, network, calendar, disk, audio

    static func kind(for widget: WidgetConfiguration, providerType: String?) -> Self? {
        if case .clock = widget.content { return .clock }
        return providerType.flatMap(Self.init(rawValue:))
    }

    func popup(timeZone: String?) -> PopupConfiguration {
        var popup = PopupConfiguration(style: WidgetStyle(fontSize: 13, width: self == .system ? 360 : self == .audio ? 340 : 320),
                                       layout: PopupBlock(content: .essentials(self, timeZone: timeZone)))
        // The Sound details' device lists open and close, and the popup grows and shrinks with them as a popup's views do.
        if self == .audio { popup.animation = WidgetAnimation() }
        return popup
    }
}

struct EssentialsDetails: View {
    let kind: EssentialsPopup
    let timeZone: String?
    /// The popup's style, which the Sound details' sliders draw with.
    let style: WidgetStyle
    let fields: [String: String]
    let context: BlockContext
    let appearance: WidgetAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch kind {
            case .clock:
                ClockCalendar(timeZone: timeZone, appearance: appearance) { context.open(OpenTarget("com.apple.iCal")!) }
            case .battery: battery
            case .system: system
            case .network: network
            case .calendar: calendar
            case .disk: disk
            case .audio: SoundDetails(style: style, fields: fields, context: context, appearance: appearance)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(appearance.foreground)
        .tint(appearance.accent)
    }

    private var battery: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                BatteryGlyph(level: context.values["percent"] ?? 0, fields: fields, iconSize: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fields["present"] == "false" ? "Power adapter" : "\(fields["percent"] ?? "—")%")
                        .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(batteryState).font(.system(size: 12)).opacity(0.6)
                }
                Spacer(minLength: 0)
            }
            if fields["present"] != "false" {
                meter(context.values["percent"] ?? 0)
                if let minutes = fields["timeRemaining"].flatMap(Int.init), minutes > 0 {
                    detail(fields["state"] == "charging" ? "Until full" : "Time remaining", "\(minutes / 60)h \(minutes % 60)m")
                }
                if let health = fields["health"] { detail("Battery health", health == "service" ? "Service recommended" : "Normal") }
            }
            Divider().overlay(appearance.foreground.opacity(0.12))
            open("Battery settings", "x-apple.systempreferences:com.apple.preference.battery", symbol: "battery.100percent")
        }
    }

    private var batteryState: String {
        switch fields["state"] {
        case "charging": "Charging"
        case "charged": "Connected to power"
        case "ac": "Connected to power"
        default: "On battery power"
        }
    }

    private var system: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                metric("CPU", value: "\(fields["cpu"] ?? "—")%", symbol: "cpu")
                metric("Memory", value: "\(fields["memory"] ?? "—")%", symbol: "memorychip")
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 8) {
                    Sparkline(samples: context.samples).stroke(appearance.accent, lineWidth: 1.5).frame(height: 34)
                    detail("User", "\(fields["cpuUser"] ?? "—")%")
                    detail("System", "\(fields["cpuSystem"] ?? "—")%")
                    detail("Load", fields["load"] ?? "—")
                    detail("Thermal", fields["thermal"]?.capitalized ?? "—")
                }
                VStack(spacing: 8) {
                    meter(context.values["memory"] ?? 0).frame(height: 34)
                    detail("Used", fields["memoryUsed"] ?? "—")
                    detail("Compressed", fields["memoryCompressed"] ?? "—")
                    detail("Swap", fields["swap"] ?? "—")
                    detail("Pressure", fields["pressure"]?.capitalized ?? "—")
                }
            }
            if let apps = context.lists["apps"], !apps.isEmpty {
                Divider().overlay(appearance.foreground.opacity(0.12))
                HStack {
                    Text("Apps").fontWeight(.semibold)
                    Spacer()
                    Text("Memory").frame(width: 68, alignment: .trailing)
                    Text("CPU").frame(width: 38, alignment: .trailing)
                    Color.clear.frame(width: 18, height: 1)
                }
                .font(.system(size: 11)).opacity(0.6)
                VStack(spacing: 9) {
                    ForEach(Array(apps.enumerated()), id: \.offset) { _, app in
                        HStack(spacing: 8) {
                            if let path = app["path"] {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
                                    .styledAppIcon(appearance.appIcons, color: appearance.foreground)
                            }
                            Text(app["name"] ?? "").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(app["memory"] ?? "").frame(width: 68, alignment: .trailing)
                            Text("\(app["cpu"] ?? "0")%").frame(width: 38, alignment: .trailing)
                            if let pid = app["pid"].flatMap(pid_t.init) {
                                Button { context.quit(pid) } label: { Image(systemName: "xmark.circle").opacity(0.55) }
                                    .buttonStyle(.plain).help("Quit \(app["name"] ?? "app")…")
                                    .accessibilityLabel("Quit \(app["name"] ?? "app")")
                                    .frame(width: 18)
                                    .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
                            }
                        }
                    }
                }
                .font(.system(size: 12)).monospacedDigit()
            }
            Divider().overlay(appearance.foreground.opacity(0.12))
            HStack {
                Text("Up \(fields["uptime"] ?? "—")").font(.system(size: 11)).opacity(0.6)
                Spacer()
                open("Activity Monitor", "com.apple.ActivityMonitor", symbol: "arrow.up.right")
            }
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                metric("Download", value: fields["downloadRate"] ?? "—", symbol: "arrow.down")
                metric("Upload", value: fields["uploadRate"] ?? "—", symbol: "arrow.up")
            }
            Divider().overlay(appearance.foreground.opacity(0.12))
            Text("Interfaces").font(.system(size: 12, weight: .semibold)).opacity(0.6)
            if (context.lists["interfaces"] ?? []).isEmpty {
                Text("No active network interfaces").opacity(0.6)
            }
            ForEach(Array((context.lists["interfaces"] ?? []).enumerated()), id: \.offset) { _, interface in
                VStack(alignment: .leading, spacing: 6) {
                    Label(interface["name"] ?? "", systemImage: "network").fontWeight(.medium)
                    HStack {
                        Text("↓ \(interface["downloadRate"] ?? "—")")
                        Spacer()
                        Text("↑ \(interface["uploadRate"] ?? "—")")
                    }
                    .font(.system(size: 12)).monospacedDigit().opacity(0.65)
                }
            }
            Divider().overlay(appearance.foreground.opacity(0.12))
            open("Network settings", "x-apple.systempreferences:com.apple.preference.network", symbol: "network")
        }
    }

    private var calendar: some View {
        VStack(alignment: .leading, spacing: 14) {
            if fields["access"] == "granted" {
                VStack(alignment: .leading, spacing: 5) {
                    Text(calendarPhase)
                        .font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(appearance.accent)
                    Text(fields["title"] ?? "No upcoming meetings").font(.system(size: 19, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if let start = fields["start"], let end = fields["end"] {
                        Text("\(start) – \(end)").font(.system(size: 12)).opacity(0.65)
                    }
                    if let minutes = fields["minutes"] {
                        Text(fields["phase"] == "live" ? "\(minutes) min remaining" : "Starts in \(minutes) min")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(appearance.accent)
                    }
                }
                if let remaining = context.values["remaining"] { meter(remaining) }
                if let link = fields["link"] { open("Join meeting", link, symbol: "video") }
                Divider().overlay(appearance.foreground.opacity(0.12))
                Text("Today").font(.system(size: 12, weight: .semibold)).opacity(0.6)
                if (context.lists["today"] ?? []).isEmpty { Text("No meetings today").opacity(0.6) }
                ForEach(Array((context.lists["today"] ?? []).enumerated()), id: \.offset) { _, event in
                    Button {
                        context.open(OpenTarget(event["link"] ?? "com.apple.iCal")!)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text(event["start"] ?? "").font(.system(size: 12)).monospacedDigit().opacity(0.6).frame(width: 52, alignment: .leading)
                            Text(event["title"] ?? "").frame(maxWidth: .infinity, alignment: .leading)
                            if event["link"] != nil { Image(systemName: "video").foregroundStyle(appearance.accent) }
                        }
                        .padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
                }
                Divider().overlay(appearance.foreground.opacity(0.12))
                open("Open Calendar", "com.apple.iCal", symbol: "calendar")
            } else {
                Label("Calendar access", systemImage: "calendar.badge.exclamationmark").font(.system(size: 17, weight: .semibold))
                Text("Allow Calendar access to see your next meeting and today’s agenda.").opacity(0.65)
                open("Calendar privacy settings", "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars", symbol: "arrow.up.right")
            }
        }
    }

    private var calendarPhase: String {
        switch fields["phase"] {
        case "live": "HAPPENING NOW"
        case "now": "STARTING SOON"
        case "soon": "COMING UP"
        default: "UP NEXT"
        }
    }

    private var disk: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(fields["volume"] ?? "—", systemImage: "internaldrive").fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(fields["format"] ?? "").font(.system(size: 12)).opacity(0.6).lineLimit(1)
                }
                Text("\(fields["percent"] ?? "—")%")
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                EssentialsMeter(value: context.values["disk"] ?? 0,
                                color: stateAccent(context.dataState, context: context, appearance: appearance), appearance: appearance)
            }
            VStack(spacing: 8) {
                detail("Used", fields["used"] ?? "—")
                detail("Free", fields["free"] ?? "—")
                detail("Capacity", fields["total"] ?? "—")
            }
            if let volumes = context.lists["volumes"], !volumes.isEmpty {
                Divider().overlay(appearance.foreground.opacity(0.12))
                Text("Other volumes").font(.system(size: 12, weight: .semibold)).opacity(0.6)
                    .accessibilityAddTraits(.isHeader)
                ForEach(volumes, id: \.["path"]) { row in
                    DiskVolumeRow(row: row, context: context, appearance: appearance)
                }
            }
            Divider().overlay(appearance.foreground.opacity(0.12))
            open("Storage settings", "x-apple.systempreferences:com.apple.settings.Storage", symbol: "gearshape")
        }
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).opacity(0.6)
            Text(value).font(.system(size: kind == .system ? 28 : 19, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).opacity(0.6)
            Spacer(minLength: 4)
            Text(value).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 11))
    }

    private func meter(_ value: Double) -> some View {
        EssentialsMeter(value: value, color: appearance.accent, appearance: appearance)
    }

    private func open(_ title: String, _ target: String, symbol: String) -> some View {
        Button { context.open(OpenTarget(target)!) } label: {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(appearance.accent)
                .padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
    }
}

private func stateAccent(_ state: String?, context: BlockContext, appearance: WidgetAppearance) -> Color {
    state.flatMap { context.stateAccents[$0] } ?? appearance.accent
}

private struct EssentialsMeter: View {
    let value: Double
    let color: Color
    let appearance: WidgetAppearance
    var height: CGFloat = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(appearance.foreground.opacity(0.1))
                .overlay(alignment: .leading) { Capsule().fill(color).frame(width: proxy.size.width * min(1, max(0, value))) }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: value)
    }
}

/// One of the disk popup's other volumes, with its eject button and the question an eject can ask.
struct DiskVolumeRow: View {
    let row: [String: String]
    let context: BlockContext
    let appearance: WidgetAppearance
    @State private var asking: Bool
    @State private var ejecting = false
    @State private var error: String?

    init(row: [String: String], context: BlockContext, appearance: WidgetAppearance, asking: Bool = false) {
        self.row = row
        self.context = context
        self.appearance = appearance
        _asking = State(initialValue: asking)
    }

    private var name: String { row["name"] ?? "" }
    private var path: String { row["path"] ?? "" }
    private var driveVolumes: String { row["driveVolumes"] ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: row["symbol"] ?? "externaldrive").frame(width: 18)
                Text(name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Text("\(row["free"] ?? "—") free").font(.system(size: 12)).monospacedDigit().opacity(0.65).lineLimit(1)
                if row["ejectable"] == "true" { ejectButton }
            }
            EssentialsMeter(value: row["fraction"].flatMap(Double.init) ?? 0,
                            color: stateAccent(row["state"], context: context, appearance: appearance),
                            appearance: appearance, height: 4)
                .padding(.leading, 26)
            if asking { question.padding(.leading, 26) }
            if let error {
                Text(error).font(.system(size: 11)).opacity(0.6).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }
        }
    }

    @ViewBuilder private var ejectButton: some View {
        if ejecting {
            ProgressView().controlSize(.mini).frame(width: 18).accessibilityLabel("Ejecting \(name)")
        } else {
            Button {
                if driveVolumes.isEmpty { eject(.drive) } else { asking.toggle() }
            } label: {
                Image(systemName: "eject").opacity(0.7).frame(width: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Eject \(name)")
            .accessibilityLabel("Eject \(name)")
            .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
        }
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Also ejects \(driveVolumes) on this drive").font(.system(size: 11)).opacity(0.6)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button { eject(.drive) } label: {
                    Text("Eject All").foregroundStyle(appearance.accentText)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(appearance.accent, in: RoundedRectangle(cornerRadius: min(appearance.cornerRadius, 6)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Eject All")
                .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
                Button { eject(.volume) } label: {
                    Text("Only \(name)").foregroundStyle(appearance.accent).lineLimit(1).truncationMode(.middle)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Only \(name)")
                .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
                Button { asking = false } label: {
                    Text("Cancel").opacity(0.7).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
                .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
            }
            .font(.system(size: 12, weight: .medium))
        }
    }

    /// Leaves the row in place on success: it goes away when the provider's next read no longer lists the volume.
    private func eject(_ scope: EjectScope) {
        asking = false
        error = nil
        ejecting = true
        Task {
            do {
                try await context.eject(path, scope)
            } catch {
                self.error = errorMessage(error)
            }
            ejecting = false
        }
    }
}
