import SwiftUI

struct SetupTourView: View {
    @Bindable var session: SetupSession
    let screen: NSScreen
    let finish: () -> Void
    let skip: () -> Void
    let reveal: () -> Void
    @State private var start: Date
    @State private var departure: Date?
    @State private var phase: Phase
    @State private var looks: [(name: String, look: Configuration)] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase { case intro, wallpaper, tour }

    private static let pages = [
        ("Start from a preset.", "Your bar changes as you choose. Presets add widgets and never remove yours."),
        ("Give it your style.", "Flip through themes with ← and →. Keep current leaves your theme as it is."),
        ("Choose where it sits.", "Below the menu bar keeps macOS menus visible. The top edge suits a menu bar that hides itself."),
        ("Try your bar.", "It's live: click a widget to open it, or right-click the bar for more. Nothing is saved until you finish.")
    ]

    init(session: SetupSession, screen: NSScreen, intro: Bool, finish: @escaping () -> Void, skip: @escaping () -> Void,
         reveal: @escaping () -> Void) {
        _session = Bindable(session)
        self.screen = screen
        self.finish = finish
        self.skip = skip
        self.reveal = reveal
        _start = State(initialValue: intro ? .now : .distantPast)
        _departure = State(initialValue: intro ? nil : .distantPast)
        _phase = State(initialValue: intro ? .intro : .tour)
    }

    private var barFrame: CGRect {
        let display = BarDisplay(screen: screen)
        guard let configuration = session.store.configuration else { return .zero }
        return CGRect(x: 0, y: configuration.onScreen(ScreenKind(display)).bar.offset,
                      width: screen.frame.width, height: configuration.barGeometry(for: display).layoutHeight)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let bar = barFrame
            ZStack {
                Color.black
                SetupBackdrop(size: size)
                    .opacity(phase == .intro ? 0.4 : 1)
                RadialGradient(colors: [.black.opacity(0.3), .black.opacity(0.75)], center: .center,
                               startRadius: size.height * 0.15, endRadius: size.width * 0.7)
                TimelineView(.animation(paused: phase == .tour)) { context in
                    intro(size: size, bar: bar, now: context.date)
                }
                if phase == .tour {
                    pointer
                        .position(x: size.width / 2, y: bar.maxY + 30)
                        .transition(.opacity)
                }
                tour(size: size)
                ZStack {
                    if phase == .tour {
                        footer.transition(.opacity.animation(.easeOut(duration: 0.4).delay(0.5)))
                    }
                }
                .position(x: size.width / 2, y: size.height - 89)
                dots.position(x: size.width / 2, y: size.height - 44)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .task {
            guard let configuration = session.store.configuration else { return }
            let themes = session.themes.filter { $0.isBundled && ["blueprint", "leman", "rose-pine"].contains($0.manifest.id) && $0.key != session.currentThemeKey }
            let directory = session.store.themesDirectory
            let previews = await Task.detached {
                themes.compactMap { theme in
                    (try? ThemePreview(choice: theme, themesDirectory: directory)).map { (name: theme.title, look: $0.dark) }
                }
            }.value
            looks = [(session.currentTheme, configuration)] + previews
        }
        .task(id: departure) {
            guard let departure, phase == .intro else { return }
            try? await Task.sleep(for: .seconds(SetupDemo.landing + departure.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            reveal()
            withAnimation(.easeInOut(duration: 0.9)) { phase = .wallpaper }
            try? await Task.sleep(for: .seconds(0.9))
            withAnimation(.smooth(duration: 0.5)) { phase = .tour }
        }
    }

    private func intro(size: CGSize, bar: CGRect, now: Date) -> some View {
        let t = now.timeIntervalSince(start)
        let d = departure.map { now.timeIntervalSince($0) } ?? -1
        let home = size.height * 0.42
        let stageWidth = min(size.width - 200, 1080)
        let stage = CGRect(x: (size.width - stageWidth) / 2, y: home - bar.height / 2, width: stageWidth, height: bar.height)
        let beam = size.width * 0.55 * UnitCurve.easeOut.value(at: progress(t, 0.45, 0.8))
        let condense = UnitCurve.easeInOut.value(at: progress(t, 1.25, 0.6))
        let shown = progress(t, 1.75, 0.4)
        let morph = UnitCurve.easeInOut.value(at: progress(d, 0.1, 0.65))
        let width = beam + (264 - beam) * condense
        let height = 2 + 66 * condense
        let leaving = 1 - progress(d, 0, 0.25)
        let ready = UnitCurve.easeOut.value(at: progress(t, 3.1, 0.45))
        let spread = UnitCurve.easeOut.value(at: progress(d, SetupDemo.landing - 0.1, 0.6))
        let shine = t > 4 ? progress(t.truncatingRemainder(dividingBy: 4.5), 0, 0.9) : 0
        let settled = t > 2
        let name = Array("StableBar")
        let ember = AngularGradient(colors: [.orange, Color(red: 1, green: 0.8, blue: 0.45), .white, .orange,
                                             .orange.opacity(0.25), .orange], center: .center, angle: .degrees(t * 80))
        let glow = LinearGradient(colors: [.clear, .orange, Color(red: 1, green: 0.8, blue: 0.45), .orange, .clear],
                                  startPoint: .leading, endPoint: .trailing)
        return ZStack {
            Rectangle()
                .fill(glow)
                .frame(width: size.width * spread, height: 2)
                .background(Rectangle().fill(glow).frame(height: 8).blur(radius: 12))
                .opacity(spread * (1 - 0.4 * progress(d, SetupDemo.landing + 0.55, 0.8)))
                .position(x: size.width / 2, y: bar.maxY)
            if d >= 0 && d < SetupDemo.landing + 0.3 && !looks.isEmpty {
                SetupDemo(looks: looks, elapsed: d, size: size, stage: stage, target: bar)
            }
            ZStack {
                Capsule()
                    .strokeBorder(LinearGradient(colors: [.white.opacity(condense), .white, .white.opacity(condense)],
                                                 startPoint: .leading, endPoint: .trailing), lineWidth: 1.5)
                    .background(Capsule().fill(.orange).blur(radius: 10).opacity(0.5 * (1 - condense)))
                    .opacity(progress(t, 0.45, 0.2) * (1 - shown))
                Group {
                    Group {
                        Capsule().fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                        Capsule().fill(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.14), location: 0.5),
                                                              .init(color: .clear, location: 1)],
                                                      startPoint: UnitPoint(x: shine * 1.6 - 0.6, y: 0),
                                                      endPoint: UnitPoint(x: shine * 1.6 - 0.2, y: 1)))
                    }
                    .opacity(1 - progress(d, 0.4, 0.4))
                    Capsule().strokeBorder(ember, lineWidth: 1.5)
                    Capsule().strokeBorder(ember, lineWidth: 4).blur(radius: 8).opacity(0.5)
                }
                .opacity(shown)
            }
            .frame(width: width + (stage.width - width) * morph, height: height + (stage.height - height) * morph)
            .overlay {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 34, height: 34)
                        .scaleEffect(settled ? 1 : 0.5)
                        .opacity(settled ? 1 : 0)
                        .animation(.spring(duration: 0.5, bounce: 0.4), value: settled)
                    HStack(spacing: 0) {
                        ForEach(name.indices, id: \.self) { index in
                            let delay = 0.1 + Double(index) * 0.055
                            Text(String(name[index]))
                                .blur(radius: settled ? 0 : 6)
                                .animation(.easeOut(duration: 0.3).delay(delay), value: settled)
                                .offset(y: settled ? 0 : -18)
                                .rotationEffect(.degrees(settled ? 0 : -12))
                                .opacity(settled ? 1 : 0)
                                .animation(.spring(duration: 0.55, bounce: 0.45).delay(delay), value: settled)
                        }
                    }
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .background(alignment: .bottomLeading) {
                        GeometryReader { proxy in
                            let glide = progress(t, 2.1, 0.55)
                            Capsule()
                                .fill(.orange)
                                .frame(width: 22, height: 4)
                                .shadow(color: .orange, radius: 6)
                                .offset(x: (proxy.size.width - 22) * UnitCurve.easeInOut.value(at: glide), y: proxy.size.height + 2)
                                .opacity(progress(t, 2.1, 0.1) * (1 - progress(t, 2.7, 0.4)))
                        }
                    }
                }
                .foregroundStyle(.white)
                .opacity(1 - progress(d, 0, 0.15))
            }
            .opacity(1 - progress(d, 1.3, 0.5))
            .position(x: size.width / 2, y: home)
            Text("A native, configurable bar for your Mac.")
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .offset(y: 8 * (1 - UnitCurve.easeOut.value(at: progress(t, 2.6, 0.45))))
                .opacity(progress(t, 2.6, 0.45) * leaving)
                .position(x: size.width / 2, y: home + 76)
            if phase == .intro {
                Button { departure = .now } label: { Text("Get Started").frame(width: 164, height: 48) }
                    .buttonStyle(SetupButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(departure != nil || t < 3.1)
                    .opacity(ready * leaving)
                    .offset(y: 12 * (1 - ready))
                    .position(x: size.width / 2, y: size.height - 89)
                Button("Skip intro") { departure = .now.addingTimeInterval(-SetupDemo.flight) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .keyboardShortcut(.cancelAction)
                    .disabled(d < 0 || d >= SetupDemo.flight)
                    .opacity(progress(d, 0.6, 0.4) * (1 - progress(d, SetupDemo.flight, 0.2)))
                    .position(x: size.width / 2, y: size.height - 89)
            }
        }
    }

    private var pointer: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up")
            Text(session.step == 3 ? "Try it on your bar" : "Live on your bar")
                .contentTransition(.opacity)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .phaseAnimator(reduceMotion ? [0] : [0, -5]) { content, offset in
            content.offset(y: offset)
        } animation: { _ in .easeInOut(duration: 1) }
    }

    private func tour(size: CGSize) -> some View {
        let page = Self.pages[session.step]
        return VStack(spacing: 12) {
            staged(0) {
                VStack(spacing: 12) {
                    Text("\(session.step + 1)  /  \(Self.pages.count)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(page.0).font(.system(size: 34, weight: .semibold)).tracking(-0.5)
                }
            }
            staged(0.08) {
                Text(page.1)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
            staged(0.16) {
                switch session.step {
                case 0: presets
                case 1: themes
                case 2: placement
                default: hints
                }
            }
            .padding(.top, 32)
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 560)
                    .padding(.top, 12)
            }
        }
        .foregroundStyle(.white)
        .padding(.top, size.height * 0.24)
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private func staged<Content: View>(_ delay: Double, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .top) {
            if phase == .tour {
                content()
                    .id(session.step)
                    .transition(.asymmetric(
                        insertion: .blurFade.combined(with: .offset(y: 12)).animation(.smooth(duration: 0.5).delay(0.22 + delay)),
                        removal: .blurFade.combined(with: .offset(y: -8)).animation(.easeIn(duration: 0.2))))
            }
        }
    }

    private var presets: some View {
        HStack(spacing: 12) {
            ForEach(SetupPreferences.Preset.allCases, id: \.self) { preset in
                let selected = session.preferences == preset.preferences(sets: session.sets)
                SetupTile(selected: selected) {
                    session.preferences = selected ? SetupPreferences() : preset.preferences(sets: session.sets)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: preset.symbol).font(.system(size: 20)).frame(height: 26)
                        Text(preset.title).font(.system(size: 15, weight: .semibold))
                        Text(preset.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(width: 168, height: 156, alignment: .topLeading)
                }
            }
        }
    }

    private var themes: some View {
        let options: [(SetupPreferences.Theme, String)] = [(.current, "Keep current"), (.builtIn, "Built-in")]
            + session.themes.map { (.package(id: $0.manifest.id, version: $0.isBundled ? nil : $0.manifest.version), $0.title) }
        let index = options.firstIndex { $0.0 == session.preferences.theme } ?? 0
        return VStack(spacing: 32) {
            HStack(spacing: 24) {
                roundButton("chevron.left", label: "Previous theme") {
                    session.preferences.theme = options[(index + options.count - 1) % options.count].0
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                VStack(spacing: 6) {
                    ZStack {
                        Text(options[index].1)
                            .font(.system(size: 28, weight: .semibold))
                            .id(index)
                            .transition(.blurFade)
                    }
                    Text(index == 0 ? "Now: \(session.currentTheme)" : "\(index) of \(options.count - 1)")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .monospacedDigit()
                }
                .frame(width: 320)
                .animation(.smooth(duration: 0.3), value: index)
                roundButton("chevron.right", label: "Next theme") {
                    session.preferences.theme = options[(index + 1) % options.count].0
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            HStack(spacing: 12) {
                Text("Appearance").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                SettingsSegments(selection: $session.preferences.appearance,
                                 options: SetupPreferences.Appearance.allCases.map { ($0, $0.rawValue) }, stretches: false)
            }
        }
    }

    private var placement: some View {
        VStack(spacing: 32) {
            HStack(spacing: 16) {
                placementTile(.top, title: "Top edge", detail: "Covers the menu bar area.")
                placementTile(.belowMenuBar, title: "Below menu bar", detail: "Keeps macOS menus visible.")
            }
            if session.placement == .top && !session.menuBarHides {
                Label("The macOS menu bar covers a bar on the top edge until it hides automatically. You can turn that on before you finish.",
                      systemImage: "menubar.rectangle")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: 520)
            }
            if session.base?.widgets.contains(where: { if case .clock = $0.content { true } else { false } }) == true {
                HStack(spacing: 12) {
                    Text("Clock").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    SettingsSegments(selection: $session.preferences.clock,
                                     options: SetupPreferences.Clock.allCases.map { ($0, $0.rawValue) }, stretches: false)
                }
            }
        }
    }

    private func placementTile(_ placement: SetupPreferences.Placement, title: String, detail: String) -> some View {
        SetupTile(selected: session.placement == placement) {
            session.preferences.placement = placement
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 3) {
                    if placement == .belowMenuBar {
                        Rectangle().fill(.white.opacity(0.4)).frame(height: 6)
                    }
                    RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.8)).frame(height: 10)
                        .padding(.horizontal, 4)
                    Spacer()
                }
                .frame(width: 232, height: 124)
                .background { Wallpaper() }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(14)
        }
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: 20) {
            hint("cursorarrow.click", "Click a widget", "Opens its details and actions.")
            hint("contextualmenu.and.cursorarrow", "Right-click the bar", "Edit Bar in Place, Try Themes and Settings.")
            hint("menubar.rectangle", "Use the menu-bar icon", "Opens Settings and this guide again.")
        }
        .padding(24)
        .frame(width: 440, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
    }

    private func hint(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.08), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var footer: some View {
        HStack(spacing: 24) {
            Button("Back") { withAnimation(.smooth(duration: 0.5)) { session.step -= 1 } }
                .opacity(session.step > 0 ? 1 : 0)
                .disabled(session.step == 0)
                .frame(width: 96, alignment: .trailing)
            Button {
                if session.step == Self.pages.count - 1 { finish() }
                else { withAnimation(.smooth(duration: 0.5)) { session.step += 1 } }
            } label: {
                Text("Continue").frame(width: 164, height: 48)
            }
            .buttonStyle(SetupButtonStyle())
            .keyboardShortcut(.defaultAction)
            Button("Skip setup", action: skip)
                .keyboardShortcut(.cancelAction)
                .frame(width: 96, alignment: .leading)
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.45))
    }

    private var dots: some View {
        let active = phase == .tour ? session.step + 1 : 0
        return HStack(spacing: 7) {
            ForEach(0...Self.pages.count, id: \.self) { index in
                Capsule()
                    .fill(index == active ? Color.orange : .white.opacity(0.3))
                    .frame(width: index == active ? 20 : 6, height: 6)
            }
        }
        .animation(.snappy, value: active)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(session.step + 1) of \(Self.pages.count)")
    }
}

/// How far `time` is through the span that begins at `start` and lasts `duration`, from 0 to 1.
func progress(_ time: Double, _ start: Double, _ duration: Double) -> Double {
    min(max((time - start) / duration, 0), 1)
}

/// Setup's two amber backgrounds, drifting and fading into each other.
private struct SetupBackdrop: View {
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let light = Wallpaper.image!
    private static let dark = NSImage(contentsOf: Bundle.main.url(forResource: "SetupAmberDark", withExtension: "heic")!)!

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                layer(Self.light, t: t, phase: 0)
                layer(Self.dark, t: t, phase: 2).opacity(0.5 + 0.5 * sin(t / 4))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func layer(_ image: NSImage, t: Double, phase: Double) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .scaleEffect(1.4 + 0.08 * sin(t / 7 + phase))
            .rotationEffect(.degrees(12 * sin(t / 11 + phase)))
            .offset(x: size.width * 0.06 * sin(t / 9 + phase), y: size.height * 0.06 * cos(t / 8 + phase))
    }
}

private struct SetupTile<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .background(.white.opacity(selected ? 0.12 : hovering ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(selected ? 0.75 : 0.1), lineWidth: selected ? 1.5 : 1))
                .shadow(color: .white.opacity(selected ? 0.18 : 0), radius: 16)
                .scaleEffect(hovering && !selected ? 1.02 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: hovering)
        .animation(.snappy(duration: 0.25), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SetupButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 28)
            .frame(minHeight: 40)
            .background(prominent ? Color.white : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

private struct Blur: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: Blur(radius: 10), identity: Blur(radius: 0)).combined(with: .opacity)
    }
}
