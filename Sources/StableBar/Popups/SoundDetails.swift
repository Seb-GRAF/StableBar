import SwiftUI

/// The Sound widget's details, in cards like Control Center's: the output and the input with their volume, mute and
/// devices, what plays in the Store's Now playing package, and the mixer, which sets each app's volume, mute and
/// output. Every color comes from the theme.
struct SoundDetails: View {
    let style: WidgetStyle
    let fields: [String: String]
    let context: BlockContext
    let appearance: WidgetAppearance
    private let mixer = AudioMixer.shared
    @State private var showsOutputs = false
    @State private var showsInputs = false
    @State private var hoversTrack = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            device(input: false, fields: fields, volume: context.values["volume"], devices: context.lists["devices"] ?? [],
                   showsDevices: $showsOutputs)
            if let input = context.providerOutput(DataSourceType.microphone.name) {
                device(input: true, fields: input.fields ?? [:], volume: input.values?["volume"], devices: input.lists?["devices"] ?? [],
                       showsDevices: $showsInputs)
            }
            if let playing = context.providerOutput(DataSourceType.nowPlaying.name)?.fields, let title = playing["title"], !title.isEmpty {
                card { music(title: title, fields: playing) }
            }
            if AudioMixer.isAvailable {
                card { apps }
            }
            link("Sound Settings…", "x-apple.systempreferences:com.apple.preference.sound")
        }
        .onAppear { mixer.start() }
    }

    /// The cards' corners, which the highlights inside them share, from the theme's.
    private var cardRadius: Double { max(appearance.cornerRadius - 2, 0) }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: cardRadius).fill(appearance.foreground.opacity(0.07)))
    }

    private func title(_ text: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if let detail, !detail.isEmpty { Text(detail).font(.system(size: 11)).opacity(0.6).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func device(input: Bool, fields: [String: String], volume: Double?, devices: [[String: String]],
                        showsDevices: Binding<Bool>) -> some View {
        let muted = fields["muted"] == "true"
        let name = input ? "Microphone" : "Sound"
        return card {
            HStack(spacing: 8) {
                title(name, detail: fields["device"] ?? (input ? "No input" : "No output"))
                if devices.count > 1 {
                    RoundButton(symbol: "chevron.down", active: false, label: showsDevices.wrappedValue ? "Hide devices" : "Show devices",
                                iconRotation: showsDevices.wrappedValue ? 180 : 0, appearance: appearance) {
                        withAnimation(reduceMotion ? nil : WidgetAnimation().value) { showsDevices.wrappedValue.toggle() }
                    }
                }
            }
            if volume != nil || fields["muted"] != nil {
                HStack(spacing: 8) {
                    if let volume {
                        level(volume, title: input ? "Input volume" : "Volume",
                              symbol: input ? "mic.fill" : AudioMonitor.icon(volume: volume, muted: false) + ".fill") {
                            context.runAction(.set(input ? .inputVolume : .volume), ["VALUE": String($0)])
                        }
                    } else {
                        Spacer()
                    }
                    if fields["muted"] != nil {
                        RoundButton(symbol: input ? "mic.slash.fill" : "speaker.slash.fill", active: muted,
                                    label: muted ? "Unmute \(name.lowercased())" : "Mute \(name.lowercased())", appearance: appearance) {
                            context.runAction(.set(input ? .inputMuted : .muted), ["VALUE": String(!muted)])
                        }
                    }
                }
            }
            if showsDevices.wrappedValue {
                VStack(spacing: 2) {
                    ForEach(devices, id: \.["id"]) { device in
                        SoundDeviceRow(name: device["name"] ?? "", selected: device["selected"] == "true", radius: cardRadius,
                                       appearance: appearance) {
                            context.selectAudioDevice(device["id"]!, input)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// A filled slider like Control Center's, drawn as the theme's slider role draws popup sliders. `set` takes its
    /// value; the block's own action stays unused.
    private func level(_ value: Double, title: String, symbol: String, height: Double = 28, set: @escaping (Double) -> Void) -> some View {
        let block = PopupBlock(content: .filledSlider(title: title, source: "level", minimum: 0, maximum: 1, step: 0.01, endStop: nil,
                                                      icon: symbol, action: .set(.volume)),
                               role: .slider, style: WidgetStyle(iconSize: height * 0.43, height: height))
        return PopupBlockView(block: block, inheritedStyle: style, fields: [:],
                              context: BlockContext(values: ["level": value], roles: context.roles, continuousSliders: true, open: { _ in },
                                                    runAction: { _, values in values["VALUE"].flatMap(Double.init).map(set) }))
    }

    /// What plays now in any app, as Control Center shows it.
    private func music(title: String, fields: [String: String]) -> some View {
        let playing = !(fields["playing"] ?? "").isEmpty
        return HStack(spacing: 8) {
            // The cover and the title bring the playing app forward.
            Button { if let app = fields["app"].flatMap(OpenTarget.init) { context.open(app) } } label: {
                HStack(spacing: 12) {
                    Group {
                        // A file of a few kilobytes, read at once so the cover doesn't flash as the card redraws.
                        if let artwork = fields["artwork"].flatMap(NSImage.init(contentsOfFile:)) {
                            Image(nsImage: artwork).resizable().scaledToFill()
                        } else {
                            artworkPlaceholder
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: min(cardRadius, 8)))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Equalizer(playing: playing, height: 10).foregroundStyle(appearance.accent).fixedSize()
                        }
                        if let artist = fields["artist"], !artist.isEmpty { Text(artist).font(.system(size: 11)).opacity(0.6).lineLimit(1) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: cardRadius).fill(appearance.foreground.opacity(hoversTrack ? 0.08 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-4)
            .onHover { hoversTrack = $0 }
            .help("Open the playing app")
            .modifier(FocusRing(cornerRadius: cardRadius))
            HStack(spacing: 2) {
                MediaButton(command: .previousTrack, symbol: "backward.fill", label: "Previous", size: 13, appearance: appearance)
                    .disabled(fields["canPrevious"] == "")
                MediaButton(command: .togglePlayPause, symbol: playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play",
                            size: 18, appearance: appearance)
                MediaButton(command: .nextTrack, symbol: "forward.fill", label: "Next", size: 13, appearance: appearance)
                    .disabled(fields["canNext"] == "")
            }
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: min(cardRadius, 8)).fill(appearance.foreground.opacity(0.1))
            .overlay { Image(systemName: "music.note").font(.system(size: 18)).opacity(0.5) }
    }

    private var apps: some View {
        let state = mixer.state
        return VStack(alignment: .leading, spacing: 12) {
            title("Apps")
            if state.shown.isEmpty { Text("No app is playing sound").font(.system(size: 12)).opacity(0.6) }
            ForEach(state.shown) { app in
                appRow(app, state: state)
            }
            switch state.permission {
            case .denied:
                Text("Allow StableBar under System Audio Recording to change each app’s sound.").font(.system(size: 11)).opacity(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                link("Privacy Settings…", "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            case .unknown where !state.shown.isEmpty:
                Text("Changing an app asks for System Audio Recording.").font(.system(size: 11)).opacity(0.6)
                    .fixedSize(horizontal: false, vertical: true)
            default: EmptyView()
            }
        }
    }

    private func appRow(_ app: MixerState.App, state: MixerState) -> some View {
        let setting = state.setting(app.id)
        let output = state.outputs.first { $0.uid == setting.output }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(nsImage: appIcon(app.id)).resizable().frame(width: 18, height: 18)
                    .styledAppIcon(appearance.appIcons, color: appearance.foreground)
                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if app.playing {
                    Equalizer(playing: true, height: 9).foregroundStyle(appearance.accent).fixedSize()
                }
                Spacer(minLength: 4)
                if state.fallsBack(app.id) {
                    Text("Output not connected").font(.system(size: 11)).opacity(0.6).lineLimit(1)
                } else if let output {
                    Text(output.name).font(.system(size: 11)).opacity(0.6).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                level(setting.muted ? 0 : setting.volume, title: "\(app.name) volume",
                      symbol: setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", height: 20) { mixer.setVolume($0, of: app.id) }
                RoundButton(symbol: "speaker.slash.fill", active: setting.muted,
                            label: setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)", size: 22, appearance: appearance) {
                    mixer.setMuted(!setting.muted, of: app.id)
                }
                Menu {
                    Picker("Output", selection: Binding(get: { setting.output }, set: { mixer.setOutput($0, of: app.id) })) {
                        Text("Default Output").tag(String?.none)
                        ForEach(state.outputs, id: \.uid) { device in
                            Text(device.name).tag(String?.some(device.uid))
                        }
                    }
                    .pickerStyle(.inline).labelsHidden()
                } label: {
                    RoundFace(symbol: "hifispeaker.fill", active: setting.output != nil, size: 22, appearance: appearance)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Output for \(app.name)").accessibilityLabel("Output for \(app.name)")
            }
            .disabled(state.permission == .denied)
        }
    }

    private func appIcon(_ id: String) -> NSImage {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
    }

    private func link(_ title: String, _ target: String) -> some View {
        SoundLink(title: title, appearance: appearance) { context.open(OpenTarget(target)!) }
    }
}

/// A button like Control Center's, as round as the theme's corners, filled with its accent while what it turns on is on.
private struct RoundButton: View {
    let symbol: String
    let active: Bool
    let label: String
    var size: Double = 28
    var iconRotation: Double = 0
    let appearance: WidgetAppearance
    let action: () -> Void

    var body: some View {
        Button(action: action) { RoundFace(symbol: symbol, active: active, size: size, iconRotation: iconRotation, appearance: appearance) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
            .modifier(FocusRing(cornerRadius: min(appearance.cornerRadius, 14)))
    }
}

/// What a round button shows, which lightens under the pointer.
private struct RoundFace: View {
    let symbol: String
    let active: Bool
    var size: Double = 28
    var iconRotation: Double = 0
    let appearance: WidgetAppearance
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(appearance.cornerRadius, size / 2))
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .rotationEffect(.degrees(iconRotation))
            .foregroundStyle(active ? appearance.accentText : appearance.foreground)
            .frame(width: size, height: size)
            .background(shape.fill(active ? appearance.accent : appearance.foreground.opacity(hovered ? 0.18 : 0.1)))
            .overlay { if active, hovered { shape.fill(appearance.accentText.opacity(0.15)) } }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

/// A play/pause, previous or next button, without a background until the pointer is over it.
private struct MediaButton: View {
    let command: NowPlaying.Command
    let symbol: String
    let label: String
    let size: Double
    let appearance: WidgetAppearance
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            Task { try? await NowPlaying.send(command) }
        } label: {
            Image(systemName: symbol).font(.system(size: size)).opacity(isEnabled ? 1 : 0.3)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: min(appearance.cornerRadius, 15))
                    .fill(appearance.foreground.opacity(hovered && isEnabled ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .onHover { hovered = $0 }
        .modifier(FocusRing(cornerRadius: min(appearance.cornerRadius, 15)))
    }
}

/// A link in the theme's accent, underlined under the pointer.
private struct SoundLink: View {
    let title: String
    let appearance: WidgetAppearance
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(appearance.accent).underline(hovered)
                .padding(.vertical, 2).padding(.horizontal, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
    }
}

/// A device in a Sound details card: a click makes it the default, and the default shows a check in the accent.
private struct SoundDeviceRow: View {
    let name: String
    let selected: Bool
    /// The corners of its highlight, the card's.
    let radius: Double
    let appearance: WidgetAppearance
    let select: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? appearance.accent : appearance.foreground.opacity(0.35))
                Text(name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background { if hovered { RoundedRectangle(cornerRadius: radius).fill(appearance.foreground.opacity(0.1)) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .modifier(FocusRing(cornerRadius: radius))
    }
}
