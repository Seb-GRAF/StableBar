import SwiftUI

struct SetupTourView: View {
    @Bindable var session: SetupSession
    /// The display setup shows on, which decides where its bar sits.
    let display: BarDisplay
    /// Reads the height of that display's macOS menu bar, which changes when setup hides or shows it.
    let menuBarHeight: () -> Double
    /// The height the Dock takes at the bottom of the screen. The tour lays out above it.
    let dock: Double
    let finish: () -> Void
    let skip: () -> Void
    let reveal: () -> Void
    let lower: () -> Void
    let showProfile: ((String) -> Void)?
    /// Plays the intro again over this setup, keeping the choices made so far.
    let watchIntro: () -> Void
    @State private var start: Date
    @State private var departure: Date?
    @State private var phase: Phase
    @State private var menuBarQuestion: Bool
    @State private var looks: [(name: String, look: Configuration)] = []
    @State private var previews: [String: ThemePreview] = [:]
    @State private var confirmingSkip = false
    /// The menu bar's height as last read, so the pointer to the bar follows the bar when the menu bar hides or shows.
    @State private var currentMenuBarHeight: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The date scenes draw at, which holds the pointer still so two drawings match.
    @Environment(\.fixedDate) private var fixedDate

    private enum Phase { case intro, wallpaper, tour }
    private var motion: SetupMotion { SetupMotion(reduceMotion: reduceMotion) }

    private var visibleWorkspaceCheckSource: WorkspaceSource? {
        phase == .tour && session.step == SetupSession.Step.touches.rawValue ? session.workspaceCheckSource : nil
    }

    /// Each step's title and text, in the order of `SetupSession.Step`.
    private static let pages = [
        ("Make it your menu bar.", "StableBar works best in the menu bar's place: it takes the top edge, and the macOS menu bar hides until you point at it."),
        ("Make it yours.", "Choose your widgets, then a theme. Your bar changes as you go."),
        ("Finishing touches.", "Choose how StableBar keeps clear of your windows and whether it opens at login."),
        ("Allow what your bar needs.", "macOS asks once for each permission. Continue when every one is allowed."),
        ("Try your bar.", "It's live: click a widget to open it, or right-click the bar for more. Nothing is saved until you finish.")
    ]


    init(session: SetupSession, display: BarDisplay, menuBarHeight: @escaping () -> Double, dock: Double, intro: Bool, finish: @escaping () -> Void,
         skip: @escaping () -> Void, reveal: @escaping () -> Void, lower: @escaping () -> Void, showProfile: ((String) -> Void)?,
         watchIntro: @escaping () -> Void = {}) {
        _session = Bindable(session)
        self.display = display
        self.menuBarHeight = menuBarHeight
        _currentMenuBarHeight = State(initialValue: menuBarHeight())
        self.dock = dock
        self.finish = finish
        self.skip = skip
        self.reveal = reveal
        self.lower = lower
        self.showProfile = showProfile
        self.watchIntro = watchIntro
        _start = State(initialValue: intro ? .now : .distantPast)
        _departure = State(initialValue: intro ? nil : .distantPast)
        _phase = State(initialValue: intro ? .intro : .tour)
        _menuBarQuestion = State(initialValue: intro && !session.menuBarHides)
    }

    /// Where the bar sits on a display `width` points wide.
    private func barFrame(width: Double) -> CGRect {
        guard let configuration = session.store.configuration else { return .zero }
        return CGRect(x: 0, y: configuration.onScreen(ScreenKind(display)).bar.top(menuBar: currentMenuBarHeight),
                      width: width, height: configuration.barGeometry(for: display).layoutHeight)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let bar = barFrame(width: size.width)
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
                    .disabled(confirmingSkip || session.applicationMove.isBusy)
                ZStack {
                    if phase == .tour {
                        footer.transition(.opacity.animation(.easeOut(duration: 0.4).delay(0.5)))
                    }
                }
                .position(x: size.width / 2, y: size.height - dock - 89)
                .disabled(session.applicationMove.isBusy)
                dots.position(x: size.width / 2, y: size.height - dock - 44)
                if confirmingSkip {
                    skipConfirmation.transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: confirmingSkip)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        // The bar moves when macOS hides or shows its menu bar, which the screen's parameters announce a moment after
        // setup's own change lands.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            currentMenuBarHeight = menuBarHeight()
            session.refreshDisplays()
        }
        .onChange(of: session.menuBarHides) { currentMenuBarHeight = menuBarHeight() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshAccess()
            session.workspaceConnection.checkAgain()
        }
        .onChange(of: visibleWorkspaceCheckSource, initial: true) {
            session.workspaceConnection.show(visibleWorkspaceCheckSource)
        }
        .onDisappear { session.workspaceConnection.hide() }
        .task(id: phase == .tour) {
            while phase == .tour && !Task.isCancelled {
                session.pollAccessibility()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: session.menuBarHides) {
            if menuBarQuestion && session.replacesMenuBar { land() }
        }
        .task {
            guard let configuration = session.store.configuration else { return }
            let themes = session.themes.filter { $0.isBundled && ["phosphor", "leman", "catppuccin"].contains($0.manifest.id) && $0.key != session.currentThemeKey }
            let directory = session.store.themesDirectory
            let previews = await Task.detached {
                themes.compactMap { theme in
                    (try? ThemePreview(choice: theme, themesDirectory: directory)).map { (name: theme.title, look: $0.dark) }
                }
            }.value
            looks = [(session.currentTheme, configuration)] + previews
            let choices = session.themes
            self.previews = await Task.detached {
                Dictionary(uniqueKeysWithValues: choices.compactMap { choice in
                    (try? ThemePreview(choice: choice, themesDirectory: directory)).map { (choice.key, $0) }
                })
            }.value
        }
        .task(id: departure) {
            guard let departure, phase == .intro, !menuBarQuestion else { return }
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
        let elapsed = departure.map { now.timeIntervalSince($0) } ?? -1
        let d = menuBarQuestion ? min(elapsed, SetupDemo.flight) : elapsed
        let home = size.height * 0.42
        let stageWidth = min(size.width - 200, 1080)
        let stage = CGRect(x: (size.width - stageWidth) / 2, y: home - bar.height / 2, width: stageWidth, height: bar.height)
        let morph = UnitCurve.easeInOut.value(at: progress(d, 0.1, 0.65))
        let leaving = 1 - progress(d, 0, 0.25)
        let ready = UnitCurve.easeOut.value(at: progress(t, 2.8, 0.45))
        let spread = UnitCurve.easeOut.value(at: progress(d, SetupDemo.landing - 0.1, 0.6))
        let warm = Color(red: 1, green: 0.8, blue: 0.45)
        let glow = LinearGradient(colors: [.clear, .orange, warm, .orange, .clear], startPoint: .leading, endPoint: .trailing)
        let openWidth = stage.width * 0.62
        let lineWidth = openWidth * 1.2
        let draw = UnitCurve.easeOut.value(at: progress(t, 0.2, 0.95))
        let swell = t < 1 ? 0 : Spring(duration: 0.8, bounce: 0.25).value(target: 1.0, time: t - 1)
        let glassWidth = lineWidth + (openWidth - lineWidth) * swell + (stage.width - openWidth) * morph
        let glassHeight = max(2, 2 + (stage.height - 2) * swell)
        let corner = min(16, glassHeight / 2)
        let sweep = t > 1.7 ? progress((t - 1.7).truncatingRemainder(dividingBy: 4.5), 0, 1.6) : 0
        let gleam = t > 3 ? progress((t - 3).truncatingRemainder(dividingBy: 5), 0, 1.5) : 0
        let pen = FeltPen(time: t)
        let glassShown = progress(t, 1, 0.05) * (1 - progress(d, SetupDemo.wipes, 0.6))
        let word = HStack(spacing: 0) {
            ForEach(Self.wordmark.indices, id: \.self) { index in
                let shown = UnitCurve.easeOut.value(at: progress(t, 1.3 + Double(index) * 0.06, 0.9))
                ZStack {
                    Self.wordmark[index].outline.stroke(Color(white: 0.07), style: StrokeStyle(lineWidth: 3.4, lineJoin: .round))
                    Self.wordmark[index].outline.fill(.white)
                }
                .frame(width: Self.wordmark[index].advance, height: CTFontGetAscent(Self.wordmarkFont) + CTFontGetDescent(Self.wordmarkFont))
                .padding(.horizontal, 9.5 * (1 - shown))
                .scaleEffect(0.96 + 0.04 * shown)
                .offset(y: 40 * (1 - shown))
                .blur(radius: 12 * (1 - shown))
                .opacity(shown)
            }
        }
        .rotationEffect(.degrees(-1.5))
        return ZStack {
            ForEach(Self.embers.indices, id: \.self) { index in
                let ember = Self.embers[index]
                let rise = t > ember.delay ? (t - ember.delay).truncatingRemainder(dividingBy: ember.duration) / ember.duration : 0
                Circle()
                    .fill(warm)
                    .frame(width: 3, height: 3)
                    .shadow(color: .orange, radius: 3)
                    .opacity(0.9 * (rise < 0.15 ? rise / 0.15 : 1 - (rise - 0.15) / 0.85) * progress(t, 0.5, 1) * (1 - progress(d, 0, 1)))
                    .position(x: size.width * ember.x + 30 * rise, y: size.height + 10 - size.height * 0.87 * rise)
            }
            pen.line(from: CGPoint(x: (size.width - lineWidth) / 2, y: home),
                     to: CGPoint(x: (size.width - lineWidth) / 2 + lineWidth * draw, y: home), width: 3.2, seed: 1)
                .fill(FeltPen.ink)
                .opacity(1 - progress(t, 1.25, 0.5))
            ZStack {
                RoundedRectangle(cornerRadius: corner)
                    .fill(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
                LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 120)
                    .rotationEffect(.degrees(12))
                    .offset(x: (glassWidth + 240) * sweep - glassWidth / 2 - 120)
                    .opacity(sweep > 0 && sweep < 1 ? 1 - morph : 0)
                HStack(spacing: 8) {
                    ghost { Image(systemName: "apple.logo") }
                    ghost { Text("Finder").fontWeight(.semibold) + Text("  File  Edit  View") }
                    Spacer(minLength: 0)
                    ghost { Image(systemName: "speaker.wave.2.fill") }
                    ghost { Text(now, format: .dateTime.weekday().day().month()) + Text("  ") + Text(now, format: .dateTime.hour().minute()) }
                    ghost { Image(systemName: "square.grid.2x2") }
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .opacity(progress(t, 1.6, 0.8) * (1 - progress(d, 0, 0.3)))
            }
            .frame(width: glassWidth, height: glassHeight)
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .opacity(glassShown)
            .position(x: size.width / 2 + 2.6, y: home + 1.9)
            pen.loop(around: CGRect(x: (size.width - glassWidth) / 2, y: home - glassHeight / 2, width: glassWidth, height: glassHeight),
                     cornerRadius: corner, width: 2.1, seed: 2)
                .fill(FeltPen.ink)
                .opacity(glassShown)
            word
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: warm, location: 0.5), .init(color: .clear, location: 0.6)],
                                   startPoint: UnitPoint(x: 2 * gleam - 1, y: 0), endPoint: UnitPoint(x: 2 * gleam, y: 0))
                        .mask(word)
                }
                .foregroundStyle(.white)
                .opacity(leaving)
                .blur(radius: 6 * (1 - leaving))
                .offset(y: -10 * (1 - leaving))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("StableBar")
                .position(x: size.width / 2, y: home - 118)
            Rectangle()
                .fill(glow)
                .frame(width: size.width * spread, height: 2)
                .background(Rectangle().fill(glow).frame(height: 8).blur(radius: 12))
                .opacity(spread * (1 - 0.4 * progress(d, SetupDemo.landing + 0.55, 0.8)))
                .position(x: size.width / 2, y: bar.maxY)
            if d >= 0 && d < SetupDemo.landing + 0.3 && !looks.isEmpty {
                SetupDemo(store: session.store, display: display, looks: looks, elapsed: d, size: size, stage: stage, target: bar)
            }
            Text("A native, configurable bar for your Mac.")
                .font(Self.handwriting)
                .foregroundStyle(FeltPen.ink)
                .offset(y: 8 * (1 - UnitCurve.easeOut.value(at: progress(t, 2.4, 0.5))))
                .opacity(progress(t, 2.4, 0.5) * leaving)
                .position(x: size.width / 2, y: home + 72)
            if phase == .intro {
                Button { departure = .now } label: { Text("Get Started").frame(width: 164, height: 48) }
                    .buttonStyle(SetupButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(departure != nil || t < 2.8)
                    .opacity(ready * leaving)
                    .offset(y: 12 * (1 - ready))
                    .position(x: size.width / 2, y: size.height - dock - 89)
                Button("Skip intro") { departure = .now.addingTimeInterval(-SetupDemo.flight) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .keyboardShortcut(.cancelAction)
                    .disabled(d < 0 || d >= SetupDemo.flight)
                    .opacity(progress(d, 0.6, 0.4) * (1 - progress(d, SetupDemo.flight, 0.2)))
                    .position(x: size.width / 2, y: size.height - dock - 89)
            }
            if menuBarQuestion && elapsed >= SetupDemo.flight {
                let asked = UnitCurve.easeOut.value(at: progress(elapsed, SetupDemo.flight, 0.45))
                VStack(spacing: 12) {
                    Text("Make it your menu bar.").font(.system(size: 34, weight: .semibold)).tracking(-0.5)
                    Text("StableBar takes the top edge, and the macOS menu bar hides until you point at it.")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.6))
                    menuBarAccessNotice
                    if let error = session.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
                .foregroundStyle(.white)
                .opacity(asked)
                .blur(radius: 8 * (1 - asked))
                .offset(y: 14 * (1 - asked))
                .position(x: size.width / 2, y: stage.minY - 110)
                HStack(spacing: 24) {
                    Button {
                        Task {
                            await session.place(.top)
                            // The menu bar may already hide, so nothing changes visibly; the choice still took effect.
                            if menuBarQuestion && session.replacesMenuBar { land() }
                        }
                    } label: {
                        Text("Replace the menu bar").frame(height: 48)
                    }
                    .buttonStyle(SetupButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.waitingForMenuBarAccess)
                    Button("Keep the menu bar") {
                        Task { await session.place(.belowMenuBar) }
                        land()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .keyboardShortcut(.cancelAction)
                }
                .opacity(asked)
                .position(x: size.width / 2, y: size.height - dock - 89)
            }
        }
    }

    private static let embers: [(x: Double, duration: Double, delay: Double)] = [
        (0.31, 7.5, 5.9), (0.57, 6.8, 1.0), (0.49, 8.7, 2.7), (0.88, 6.3, 4.4), (0.45, 7.4, 1.8), (0.18, 7.3, 7.6),
        (0.09, 10.1, 6.5), (0.92, 7.4, 1.7), (0.37, 9.1, 6.0), (0.46, 6.4, 5.0), (0.78, 7.9, 2.4), (0.33, 8.4, 1.2),
        (0.93, 10.3, 4.6), (0.38, 6.0, 2.7), (0.81, 10.4, 6.9), (0.6, 7.0, 3.7), (0.37, 8.2, 1.7), (0.39, 7.3, 6.5)
    ]

    private static let wordmarkFont = shantellSans("shantell-sans-display", size: 76)
    private static let wordmark: [(outline: Path, advance: Double)] = "StableBar".utf16.map { character in
        var character = character, glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(wordmarkFont, &character, &glyph, 1)
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CTFontGetAscent(wordmarkFont))
        return (Path(CTFontCreatePathForGlyph(wordmarkFont, glyph, &flip)!), CTFontGetAdvancesForGlyphs(wordmarkFont, .horizontal, &glyph, nil, 1))
    }
    private static let handwriting = Font(shantellSans("shantell-sans-hand", size: 20))

    private func ghost<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
    }

    private func land() {
        menuBarQuestion = false
        session.step = SetupSession.Step.look.rawValue
        departure = .now.addingTimeInterval(-SetupDemo.flight)
    }

    /// Hiding or showing the menu bar waits for Automation access to System Events instead of failing.
    @ViewBuilder private var menuBarAccessNotice: some View {
        if session.waitingForMenuBarAccess {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("macOS asks to let StableBar control System Events. Choose Allow to change the menu bar.")
            }
            .font(.callout)
            .foregroundStyle(.white.opacity(0.75))
        } else if let placement = session.placementAwaitingAccess {
            VStack(spacing: 10) {
                Label("StableBar needs Automation access to \(placement == .top ? "hide" : "show") the macOS menu bar. \(MenuBarAutoHide.accessHint)",
                      systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Automation Settings…") {
                    lower()
                    MenuBarAutoHide.openAutomationSettings()
                }
                .buttonStyle(SetupButtonStyle(prominent: false))
            }
        }
    }

    private var pointer: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up")
            Text(session.step == Self.pages.count - 1 ? "Try it on your bar" : "Live on your bar")
                .contentTransition(.opacity)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .phaseAnimator(reduceMotion || fixedDate != nil ? [0] : [0, -5]) { content, offset in
            content.offset(y: offset)
        } animation: { _ in .easeInOut(duration: 1) }
    }

    private func tour(size: CGSize) -> some View {
        let page = Self.pages[session.step]
        let layout = SetupTourLayout(height: size.height, dock: dock)
        return VStack(spacing: 16) {
            ScrollView(.vertical) {
            VStack(spacing: 12) {
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
                switch SetupSession.Step(rawValue: session.step) {
                case .placement: placement
                case .look:
                    VStack(spacing: 28) {
                        section("Widgets") {
                            Text("Presets add widgets and never remove yours.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                        } content: {
                            presets
                        }
                        section("Theme") {
                            HStack(spacing: 20) {
                                if session.store.configuration?.widgets.contains(where: { if case .clock = $0.content { true } else { false } }) == true {
                                    HStack(spacing: 10) {
                                        Text("Clock").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                                        SettingsSegments(selection: $session.preferences.clock,
                                                         options: SetupPreferences.Clock.allCases.map { ($0, $0.rawValue) }, stretches: false)
                                    }
                                }
                                HStack(spacing: 10) {
                                    Text("Appearance").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                                    SettingsSegments(selection: $session.preferences.appearance,
                                                     options: SetupPreferences.Appearance.allCases.map { ($0, $0.rawValue) }, stretches: false)
                                }
                            }
                        } content: {
                            themes
                        }
                    }
                case .touches: access
                case .permissions: permissions
                default: hints
                }
            }
            .padding(.top, layout.controlsGap)
            if phase == .tour, let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 560)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            // A step taller than the room fades out at the bottom, so it reads as scrolling on.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 16)
                }
            }
            // After the permissions step, what is still missing sits above Finish setup, which waits for it, however
            // long the step is.
            if phase == .tour, session.step > SetupSession.Step.permissions.rawValue, !session.missingPermissions.isEmpty {
                permissionReminder
                    .transaction { motion.suppressMovement(in: &$0) }
                    .transition(.opacity)
            }
        }
        .padding(.top, layout.contentTop)
        .padding(.bottom, size.height - layout.footerTop)
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private var permissionReminder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow these before you finish")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            ForEach(session.missingPermissions, id: \.self) { permissionRow($0, compact: true) }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 600, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.orange.opacity(0.3)))
    }

    private func staged<Content: View>(_ delay: Double, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .top) {
            if phase == .tour {
                content()
                    // Suppress the controls' own animations inside the step, keeping its outer crossfade.
                    .transaction { motion.suppressMovement(in: &$0) }
                    .id(session.step)
                    .transition(motion.stepTransition(delay: delay))
            }
        }
    }

    private func section<Trailing: View, Content: View>(_ title: String, @ViewBuilder trailing: () -> Trailing,
                                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                trailing()
            }
            content()
        }
        .frame(width: 948)
    }

    private var presets: some View {
        HStack(spacing: 12) {
            ForEach(session.offeredPresets, id: \.self) { preset in
                let selected = session.preset == preset
                let sets = session.shownWidgetSets(preset)
                SetupTile(selected: selected) {
                    session.toggle(preset)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Image(systemName: preset.symbol).font(.system(size: 15))
                            Spacer()
                            if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 15)) }
                        }
                        .frame(height: 20)
                        .accessibilityHidden(true)
                        Text(preset.title).font(.system(size: 15, weight: .semibold)).padding(.top, 10)
                        Text(preset.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).padding(.top, 2)
                        Spacer(minLength: 12)
                        HStack(spacing: 4) {
                            if session.presetPlacement == .belowMenuBar {
                                // Below the menu bar, the starter has Workspaces, System and Sound.
                                let workspaces = SetupPreferences.WidgetSet.workspaces(session.workspaceSource)
                                Image(systemName: workspaces.symbol).opacity(sets.contains(workspaces) ? 1 : 0.45)
                                Spacer(minLength: 2)
                                Image(systemName: SetupPreferences.WidgetSet.system.symbol).opacity(sets.contains(.system) ? 1 : 0.45)
                                ForEach(sets.filter { if case .workspaces = $0 { false } else { $0 != .system && $0 != .menuBarItems } },
                                        id: \.self) { Image(systemName: $0.symbol) }
                            } else {
                                Image(systemName: "apple.logo").opacity(0.45)
                                ForEach(sets.filter { if case .workspaces = $0 { true } else { false } }, id: \.self) { Image(systemName: $0.symbol) }
                                Image(systemName: "menubar.rectangle").opacity(0.45)
                                Spacer(minLength: 2)
                                ForEach(sets.filter { if case .workspaces = $0 { false } else { $0 != .menuBarItems } }, id: \.self) { Image(systemName: $0.symbol) }
                                Image(systemName: "clock").opacity(0.45)
                                if sets.contains(.menuBarItems) { Image(systemName: SetupPreferences.WidgetSet.menuBarItems.symbol) }
                            }
                        }
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                    }
                    .padding(14)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 140, maxHeight: 140, alignment: .topLeading)
                }
                .help("Adds \(ListFormatter.localizedString(byJoining: sets.map(\.title))).")
                .accessibilityLabel(preset.accessibilityLabel(widgetSets: sets, placement: session.presetPlacement))
            }
        }
    }

    private var themes: some View {
        let choices = session.themes
        let selected = session.store.selectedThemeKey
        let index = choices.firstIndex { $0.key == selected } ?? 0
        let appearance = session.store.configuration?.bar.appearance ?? (session.store.context.appearance == "dark" ? .dark : .light)
        return HStack(spacing: 16) {
            roundButton("chevron.left", label: "Previous theme") {
                choose(choices[(index + choices.count - 1) % choices.count])
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            ScrollViewReader { scroll in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(choices, id: \.key) { choice in
                            themeTile(choice, appearance: appearance, selected: choice.key == selected) { focused in
                                if focused {
                                    withAnimation(motion.movement(.smooth(duration: 0.3))) {
                                        scroll.scrollTo(choice.key, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
                .onAppear { scroll.scrollTo(selected, anchor: .center) }
                .onChange(of: selected) {
                    withAnimation(motion.movement(.smooth(duration: 0.3))) { scroll.scrollTo(selected, anchor: .center) }
                }
            }
            .frame(width: 836)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05),
                                         .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            roundButton("chevron.right", label: "Next theme") {
                choose(choices[(index + 1) % choices.count])
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    private func themeTile(_ choice: ThemeChoice, appearance: BarAppearance, selected: Bool,
                           focusChanged: @escaping (Bool) -> Void) -> some View {
        SetupTile(selected: selected, focusChanged: focusChanged) {
            choose(choice)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let look = previews[choice.key]?.configuration(for: appearance) {
                        GeometryReader { proxy in
                            ThemeSampleBar(look: look)
                                .frame(width: proxy.size.width * 2)
                                .scaleEffect(0.5)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                    }
                }
                .frame(height: 46)
                .background(SampleWallpaper())
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .environment(\.colorScheme, appearance.colorScheme)
                HStack(spacing: 6) {
                    Text(choice.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    if choice.key == session.currentThemeKey {
                        Text("Current").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 2)
            }
            .padding(8)
            .frame(width: 168)
        }
        .id(choice.key)
        .accessibilityLabel("\(choice.title) theme")
    }

    private func choose(_ choice: ThemeChoice) {
        session.preferences.theme = choice.key == session.currentThemeKey ? .current
            : choice.isBuiltIn ? .builtIn : .package(id: choice.manifest.id, version: choice.isBundled ? nil : choice.manifest.version)
    }

    /// Where the bar sits. Replacing the menu bar is the larger choice, since StableBar works best in its place;
    /// keeping it is one click away underneath.
    private var placement: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                SetupTile(selected: session.placementChoice == .top) {
                    Task { await session.place(.top) }
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        placementPicture(.top, width: 488, height: 150)
                        HStack(spacing: 8) {
                            Text("Replace the menu bar").font(.system(size: 15, weight: .semibold))
                            Text("Recommended")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.white.opacity(0.14), in: Capsule())
                        }
                        Text("StableBar takes the top edge. The macOS menu bar hides until you point at it.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 488, alignment: .leading)
                    .padding(14)
                }
                SetupTile(selected: session.placementChoice == .belowMenuBar) {
                    Task { await session.place(.belowMenuBar) }
                } label: {
                    HStack(spacing: 14) {
                        placementPicture(.belowMenuBar, width: 84, height: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep the menu bar").font(.system(size: 13, weight: .semibold))
                            Text("StableBar sits below it, and macOS menus stay visible.")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(width: 488)
                }
            }
            menuBarAccessNotice
            // A profile that places the bar keeps it where it is, whichever choice this step saves.
            profileNotice(ProfileControlledSetting.placement(origins: session.store.origins))
            Button {
                watchIntro()
            } label: {
                Label("Watch the intro", systemImage: "play.circle")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// A small screen with the bar on the top edge, or under a menu bar.
    private func placementPicture(_ placement: SetupPreferences.Placement, width: Double, height: Double) -> some View {
        VStack(spacing: 3) {
            if placement == .belowMenuBar {
                Rectangle().fill(.white.opacity(0.4)).frame(height: 6)
            }
            RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.8)).frame(height: 10)
                .padding(.horizontal, 4)
            Spacer()
        }
        .frame(width: width, height: height)
        .background { Wallpaper() }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var hints: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 20) {
                hint("cursorarrow.click", "Click a widget", "Opens its details and actions.")
                hint("contextualmenu.and.cursorarrow", "Right-click the bar", "Edit Bar in Place, Try Themes and Settings.")
                hint("menubar.rectangle", "Use the menu-bar icon", "Opens Settings and this guide again.")
            }
            .padding(24)
            .frame(width: 440, alignment: .leading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
            profileNotice(ProfileControlledSetting.all(in: session.store.configuration, origins: session.store.origins))
        }
    }

    @ViewBuilder private func profileNotice(_ profileSettings: [ProfileControlledSetting]) -> some View {
        if !profileSettings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Active profiles control some settings", systemImage: "info.circle").font(.system(size: 13, weight: .semibold))
                ForEach(profileSettings) { setting in
                    Text("\(setting.title): \(session.store.sourceText(setting.origin)).")
                    if let showProfile, let profile = setting.origin.profile {
                        Button("Edit \(profile) profile…") {
                            lower()
                            showProfile(profile)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.8))
                    }
                }
                Text("Setup saves your defaults. These profiles still take priority, so a saved change may not change the bar now. Review the controlling settings in Profiles.")
                if let configuration = session.store.configuration {
                    Text("Effective placement: \(configuration.bar.placementDescription).")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.6))
            .frame(width: 440, alignment: .leading)
        }
    }

    var clearanceStartNotice: String {
        session.system.macOSVersion.supportsNotificationClearance
            ? "Window and notification clearance start when you finish setup."
            : "Window clearance starts when you finish setup."
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 18) {
            if session.preferences.widgetSets.contains(.meetings) && session.preferences.deferMeetings {
                HStack {
                    Text("Meetings will stay turned off. Turn it on in Settings → Bar when you are ready to allow Calendar access.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Set up Calendar access now") { session.preferences.deferMeetings = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            hint("macwindow", "Keep windows clear of StableBar", "Moves and resizes ordinary windows. Fullscreen windows stay unchanged.") {
                Toggle("Keep windows clear of StableBar", isOn: Binding(
                    get: { session.keepsWindowsClear },
                    set: { session.preferences.keepWindowsClear = $0 }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if session.system.macOSVersion.supportsNotificationClearance {
                hint("bell", "Keep notifications clear of StableBar", "Moves banners below the bar.") {
                    Toggle("Keep notifications clear of StableBar", isOn: Binding(
                        get: { session.preferences.keepNotificationsClear ?? (session.base?.bar.keepNotificationsClear == true) },
                        set: { session.preferences.keepNotificationsClear = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            hint("power", "Open at login", session.system.isInApplications()
                 ? "Starts StableBar when you log in." : "Move StableBar to Applications to start it at login.") {
                if session.system.isInApplications() {
                    Toggle("Open at login", isOn: Binding(get: { session.opensAtLogin }, set: { session.openAtLogin = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                } else {
                    ApplicationMoveControls(controller: session.applicationMove, resume: session.resumeAfterMoving,
                                            reveal: lower, setup: true)
                }
            }
            Text(clearanceStartNotice)
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            let source = session.adviceSource
            if source != .spaces {
                Text("\(source.title) detected. Leave window clearance off if it already manages your gaps. \(source == .yabai ? "Use yabai’s external_bar setting to leave room for the bar." : "Set gaps.outer.top in \(source.title) to leave room for the bar.")")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
            if let source = session.workspaceCheckSource {
                workspaceConnection(source)
            }
        }
        .padding(24)
        .frame(width: 600, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
    }

    private func workspaceConnection(_ source: WorkspaceSource) -> some View {
        @Bindable var connection = session.workspaceConnection
        let result = connection.result
        let (title, detail): (String, String) = switch result {
        case .checking: ("Workspaces · \(source.title)", "Checking the connection…")
        case .connected: ("Workspaces · \(source.title)", "Connected and ready to refresh.")
        case let .signalsMissing(configuration):
            ("Let yabai refresh Workspaces", "Add refresh signals to \(configuration), then run yabai --restart-service.")
        case let .reloadYabai(configuration):
            ("Load yabai’s refresh signals", "The signals are in \(configuration). Run yabai --restart-service, then check again.")
        case .ipcOff: ("Connect Workspaces to OmniWM", "Turn on Enable IPC in OmniWM’s menu, then check again.")
        case let .couldntCheck(reason): ("Workspaces · \(source.title)", reason)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(.white.opacity(0.1))
            hint("square.grid.2x2", title, detail) {
                if connection.isChecking || result == .checking {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking \(source.title)")
                } else if result == .connected {
                    Label("Connected", systemImage: "checkmark")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                }
            }
            if case .signalsMissing = result {
                DisclosureGroup("Show signals to add", isExpanded: $connection.showsSignals) {
                    ScrollView(.horizontal) {
                        Text(session.yabaiSignalScript)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(10)
                    }
                    .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                }
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
            }
            if result != .checking {
                HStack(spacing: 16) {
                    Button("Check Again", action: connection.checkAgain)
                        .disabled(connection.isChecking)
                    if case .signalsMissing = result {
                        Button("Copy signals") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(session.yabaiSignalScript, forType: .string)
                        }
                    }
                    Button("\(source.title) guide ↗") {
                        lower()
                        NSWorkspace.shared.open(URL(string: "https://github.com/Seb-GRAF/StableBar/blob/main/docs/widgets.md#\(source == .yabai ? "yabai" : "omniwm")-workspaces")!)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            }
            if result != .connected {
                Text("You can finish setup now. Workspaces may stay stale until this is ready.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(session.neededPermissions, id: \.self) { permissionRow($0) }
            if session.showsSpacesGuidance {
                let status = session.store.workspaceStore.desktopShortcutStatus
                hint("keyboard", DesktopShortcuts.title, status.detail) {
                    if status.allEnabled {
                        Label("Ready", systemImage: "checkmark").font(.system(size: 13)).foregroundStyle(SettingsPalette.success)
                    } else {
                        permissionButton(DesktopShortcuts.actionTitle) {
                            lower()
                            do { try DesktopShortcuts.openSettings() }
                            catch { session.error = errorMessage(error) }
                        }
                        .fixedSize()
                    }
                }
                if !status.allEnabled {
                    Text("You can continue setup and turn these on later. Only switching desktops from the bar needs them.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .padding(24)
        .frame(width: 600, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
        .onAppear { session.store.workspaceStore.refreshDesktopShortcuts() }
    }

    /// A permission with its state and action. `compact` drops the explanation and keeps the row on one line, for the
    /// reminder on the last step; the permissions step explains each one.
    private func permissionRow(_ permission: SetupPermission, compact: Bool = false) -> some View {
        let hides = (session.placementAwaitingAccess ?? session.placement) == .top
        let (symbol, title, detail) = switch permission {
        case .accessibility:
            ("accessibility", "Accessibility",
             "App menus, the Apple menu and Menu bar items open macOS menus. Window clearance and switching desktops use it too.")
        case .automation:
            ("menubar.rectangle", "Automation", "Lets StableBar control System Events to \(hides ? "hide" : "show") the macOS menu bar.")
        case .calendars:
            ("calendar", "Calendars", "Meetings shows your next meeting and today's agenda.")
        }
        return hint(symbol, title, compact ? "" : detail) {
            if session.isAllowed(permission) {
                allowedLabel
            } else if permission == .automation && session.waitingForMenuBarAccess {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("macOS is asking…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                }
            } else if compact {
                HStack(spacing: 14) {
                    permissionEscape(permission, hides: hides)
                    permissionAction(permission)
                }
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    permissionAction(permission)
                    permissionEscape(permission, hides: hides)
                }
            }
        }
    }

    @ViewBuilder private func permissionAction(_ permission: SetupPermission) -> some View {
        switch permission {
        case .accessibility:
            permissionButton(.allow, for: permission) {
                lower()
                session.store.windowClearance.requestAccess()
            }
        case .automation:
            if session.automationAccess == .denied {
                permissionButton(.openSettings, for: permission) {
                    lower()
                    MenuBarAutoHide.openAutomationSettings()
                }
            } else {
                permissionButton(.allow, for: permission) { Task { await session.allowAutomation() } }
            }
        case .calendars:
            if session.calendarAccess == .notDetermined {
                permissionButton(.allow, for: permission) { Task { await session.requestCalendarAccess() } }
            } else {
                permissionButton(.openSettings, for: permission) {
                    lower()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            }
        }
    }

    /// The choice that drops the need: keeping the menu bar, or setting up Meetings later.
    @ViewBuilder private func permissionEscape(_ permission: SetupPermission, hides: Bool) -> some View {
        if permission == .automation && hides {
            escapeButton("Keep the menu bar instead") { Task { await session.place(.belowMenuBar) } }
        } else if permission == .calendars && session.needsCalendarSetup {
            escapeButton("Set up Meetings later") { session.preferences.deferMeetings = true }
        }
    }

    private var allowedLabel: some View {
        Label("Allowed", systemImage: "checkmark").font(.system(size: 13)).foregroundStyle(SettingsPalette.success)
    }

    private func permissionButton(_ kind: SetupPermission.Action, for permission: SetupPermission,
                                  action: @escaping () -> Void) -> some View {
        permissionButton(kind.title, accessibilityLabel: kind.accessibilityLabel(for: permission), action: action)
    }

    private func permissionButton(_ title: String, accessibilityLabel: String? = nil,
                                  action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(SetupButtonStyle(prominent: false))
            .accessibilityLabel(accessibilityLabel ?? title)
            .accessibilityInputLabels([Text(title), Text(accessibilityLabel ?? title)])
    }

    private func escapeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.6))
    }

    private func hint<Control: View>(_ symbol: String, _ title: String, _ detail: String,
                                     @ViewBuilder control: () -> Control = { EmptyView() }) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
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
            Button("Back") { withAnimation(motion.stepAnimation) { session.step -= 1 } }
                .opacity(session.step > 0 ? 1 : 0)
                .disabled(session.step == 0)
                .frame(width: 96, alignment: .trailing)
            Button {
                if session.step == Self.pages.count - 1 {
                    session.finish()
                    if session.finished { finish() }
                } else {
                    withAnimation(motion.stepAnimation) { session.step += 1 }
                }
            } label: {
                Text(session.step == Self.pages.count - 1 ? "Finish setup" : "Continue").frame(width: 164, height: 48)
            }
            .buttonStyle(SetupButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(SetupSession.Step(rawValue: session.step).map(session.blocksContinue) ?? false)
            Button("Skip setup") { if session.hasChanges { confirmingSkip = true } else { skip() } }
                .keyboardShortcut(.cancelAction)
                .frame(width: 96, alignment: .leading)
        }
        .disabled(confirmingSkip)
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.45))
    }

    /// Asks before Skip setup, or Esc, throws away the choices made so far.
    private var skipConfirmation: some View {
        ZStack {
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture { confirmingSkip = false }
            VStack(spacing: 12) {
                Text("Skip setup?").font(.system(size: 26, weight: .semibold))
                Text("""
                    Nothing you chose is saved\(session.changedMenuBar ? ", and the macOS menu bar goes back to how it was" : ""). \
                    Open it again any time with Getting Started… in the menu-bar icon's menu, or in Settings → General.
                    """)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Skip Setup") {
                        confirmingSkip = false
                        skip()
                    }
                    .buttonStyle(SetupButtonStyle(prominent: false))
                    Button("Keep Setting Up") { confirmingSkip = false }
                        .buttonStyle(SetupButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 10)
                // Esc keeps setting up while the question shows.
                Button("") { confirmingSkip = false }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(32)
            .background(Color(white: 0.11).opacity(0.96), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12)))
        }
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
        .animation(motion.movement(.snappy), value: active)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.progressLabel(step: phase == .tour ? session.step : nil, count: Self.pages.count))
    }

    /// The intro has its own dot, before the five numbered steps.
    static func progressLabel(step: Int?, count: Int) -> String {
        step.map { "Step \($0 + 1) of \(count)" } ?? "Introduction"
    }
}

/// How far `time` is through the span that begins at `start` and lasts `duration`, from 0 to 1.
func progress(_ time: Double, _ start: Double, _ duration: Double) -> Double {
    min(max((time - start) / duration, 0), 1)
}

/// Setup's day and dusk backgrounds, in the landing page's colors, drifting and fading into each other.
private struct SetupBackdrop: View {
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The date scenes draw at: the backdrop stops there, so two drawings match.
    @Environment(\.fixedDate) private var fixedDate

    /// Missing outside the app bundle, as in tests, where the backdrop stays black.
    private static let light = Wallpaper.image
    private static let dark = Bundle.main.url(forResource: "SetupDusk", withExtension: "heic").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || fixedDate != nil)) { context in
            let t = (fixedDate ?? context.date).timeIntervalSinceReferenceDate
            ZStack {
                layer(Self.light, t: t, phase: 0)
                layer(Self.dark, t: t, phase: 2).opacity(0.5 + 0.5 * sin(t / 4))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func layer(_ image: NSImage?, t: Double, phase: Double) -> some View {
        Image(nsImage: image ?? NSImage())
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .scaleEffect(1.4 + 0.08 * sin(t / 7 + phase))
            .rotationEffect(.degrees(12 * sin(t / 11 + phase)))
            .offset(x: size.width * 0.06 * sin(t / 9 + phase), y: size.height * 0.06 * cos(t / 8 + phase))
    }
}

struct SetupTile<Label: View>: View {
    let selected: Bool
    var focusChanged: (Bool) -> Void = { _ in }
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false
    @State private var clearingFocus = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: SetupMotion { SetupMotion(reduceMotion: reduceMotion) }

    var body: some View {
        Button {
            clearingFocus = true
            focused = false
            action()
        } label: {
            label
                .background(.white.opacity(selected ? 0.12 : hovering ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(selected ? 0.75 : 0.1), lineWidth: selected ? 1.5 : 1))
                .shadow(color: .white.opacity(selected ? 0.18 : 0), radius: 16)
                .scaleEffect(motion.scale(hovering && !selected, to: 1.02))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 14))
        // Unrestricted focus includes Tab without macOS's Keyboard navigation setting, from macOS 14 on.
        .focusable(isEnabled)
        .focused($focused)
        .focusEffectDisabled(false)
        .task { focused = false }
        .onChange(of: focused) {
            // AppKit can assign mouse focus after the button's action; dismiss that ring too.
            if clearingFocus {
                focused = false
                clearingFocus = false
            }
            focusChanged(focused)
        }
        .onKeyPress(keys: [.space], phases: .down) { _ in
            guard isEnabled else { return .ignored }
            action()
            return .handled
        }
        .onHover { hovering = $0 }
        .animation(motion.movement(.snappy(duration: 0.2)), value: hovering)
        .animation(motion.movement(.snappy(duration: 0.25)), value: selected)
        .accessibilityAction { action() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SetupButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let motion = SetupMotion(reduceMotion: reduceMotion)
        return configuration.label
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 28)
            .frame(minHeight: 40)
            .background(prominent ? Color.white : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? configuration.isPressed ? 0.8 : 1 : 0.35)
            .scaleEffect(motion.scale(configuration.isPressed, to: 0.97))
            .animation(motion.movement(.snappy(duration: 0.15)), value: configuration.isPressed)
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

/// Where setup's steps sit on a screen `height` points tall whose Dock takes `dock` points at the bottom. A step starts
/// a quarter of the way down, closer on a short screen, and scrolls before it reaches Back, Continue and Skip setup.
struct SetupTourLayout {
    /// Below the bar and the "Live on your bar" pointer.
    static let minimumContentTop = 120.0
    /// The room the tallest step takes: Make it yours with a permission reminder.
    static let roomyContent = 600.0
    let height: Double
    let dock: Double

    /// The top of the footer's buttons, which are centered 89 points above the Dock, with a margin.
    var footerTop: Double { height - dock - 89 - 24 - 20 }
    var contentTop: Double { max(Self.minimumContentTop, min((height - dock) * 0.24, footerTop - Self.roomyContent)) }
    var contentHeight: Double { max(0, footerTop - contentTop) }
    /// The space between a step's text and its controls, tighter on a short screen.
    var controlsGap: Double { contentTop < (height - dock) * 0.24 ? 20 : 32 }
}
