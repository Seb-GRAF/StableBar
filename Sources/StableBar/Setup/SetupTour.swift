import ServiceManagement
import SwiftUI

struct SetupTourView: View {
    @Bindable var session: SetupSession
    /// The display setup shows on, which decides where its bar sits.
    let display: BarDisplay
    /// Reads the height of that display's macOS menu bar, which changes when setup hides or shows it.
    let menuBarHeight: () -> Double
    /// The height the Dock takes at the bottom of the screen. The tour lays out above it.
    let dock: Double
    /// Closes setup, once it's finished or to skip it.
    let close: () -> Void
    /// Puts the tour under the macOS menu bar but over the bar for the stage, under the bar once it's in place, or under
    /// System Settings. The intro's dim covers the menu bar too, until the question shows.
    let raise: () -> Void
    let reveal: () -> Void
    let lower: () -> Void
    let editBar: (() -> Void)?
    @State private var opened = Date.now
    /// Whether the intro still covers the macOS menu bar, which would hide macOS's own prompts.
    @State private var covering = true
    /// Whether the intro still plays, and whether the bar has finished landing: the tour animates only then.
    @State private var intro = true
    @State private var landed = false
    /// When the bar left the stage for its place.
    @State private var departure: Date?
    @State private var previews: [String: ThemePreview] = [:]
    @State private var confirmingSkip = false
    @State private var reviewIsWorking = false
    @State private var showsSuggestions = false
    /// The menu bar's height as last read, so the bar's place follows it when the menu bar hides or shows.
    @State private var currentMenuBarHeight: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The date scenes draw at, which shows every animation finished.
    @Environment(\.fixedDate) private var fixedDate

    private var motion: SetupMotion { SetupMotion(reduceMotion: reduceMotion) }
    private static let ink = Color(red: 0.949, green: 0.933, blue: 1)
    private static let warm = Color(red: 1, green: 0.8, blue: 0.45)
    private static let gold = Color(red: 0.847, green: 0.698, blue: 0.369)
    private static let panel = Color(red: 0.11, green: 0.11, blue: 0.125).opacity(0.9)
    private static let handwriting = Font(shantellSans("shantell-sans-hand", size: 19))
    /// The steps the toolbar's dots count.
    private static let choosing: [SetupSession.Step] = [.widgets, .look, .tune]

    init(session: SetupSession, display: BarDisplay, menuBarHeight: @escaping () -> Double, dock: Double, close: @escaping () -> Void,
         raise: @escaping () -> Void, reveal: @escaping () -> Void, lower: @escaping () -> Void, editBar: (() -> Void)?) {
        _session = Bindable(session)
        self.display = display
        self.menuBarHeight = menuBarHeight
        _currentMenuBarHeight = State(initialValue: menuBarHeight())
        self.dock = dock
        self.close = close
        self.raise = raise
        self.reveal = reveal
        self.lower = lower
        self.editBar = editBar
    }

    /// Where the bar sits on a display of `size`, measured down from its top.
    private func barFrame(in size: CGSize) -> CGRect {
        guard let configuration = session.store.configuration else { return .zero }
        let frame = configuration.onScreen(ScreenKind(display)).bar.frame(height: configuration.barGeometry(for: display).layoutHeight,
                                                                           on: CGRect(origin: .zero, size: size), menuBar: currentMenuBarHeight)
        return CGRect(x: 0, y: size.height - frame.maxY, width: size.width, height: frame.height)
    }

    /// The bar in the middle of the screen, before it takes its place.
    private func stageFrame(in size: CGSize, height: Double) -> CGRect {
        let width = min(size.width - 240, 1100)
        return CGRect(x: (size.width - width) / 2, y: size.height * 0.45 - height / 2, width: width, height: height)
    }

    /// The Mac's appearance, which the wallpaper follows, while the tour itself stays dark.
    private var macScheme: ColorScheme {
        session.store.configurationStore.context.appearance == "dark" ? .dark : .light
    }

    private var barAppearance: BarAppearance {
        session.store.configuration?.bar.appearance ?? (macScheme == .dark ? .dark : .light)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let bar = barFrame(in: size)
            TimelineView(.animation(paused: fixedDate != nil || !(intro || departure != nil && !landed))) { context in
                // Scenes draw the intro finished.
                let t = fixedDate == nil ? context.date.timeIntervalSince(opened) : 60
                let flown = departure.map { context.date.timeIntervalSince($0) } ?? -1
                let flight = session.step == .menuBar ? UnitCurve.easeInOut.value(at: progress(flown, 0, 0.9)) : 1
                let stage = stageFrame(in: size, height: bar.height)
                let window = reduceMotion && session.step == .menuBar ? stage : interpolate(stage, bar, flight)
                ZStack {
                    dim(size: size, t: t)
                    background(size: size, window: window, corner: 14 * (1 - flight), t: t)
                    if session.step == .menuBar {
                        stageBar(window, corner: 14 * (1 - flight), t: t, flown: flown)
                        ask(size: size, stage: stage, t: t)
                            .opacity(1 - progress(flown, 0, 0.3))
                    }
                    glowLine(width: size.width, flight: flight, flown: flown)
                        .position(x: size.width / 2, y: bar.maxY)
                }
            }
            ZStack {
                if [.widgets, .look].contains(session.step) {
                    live.position(x: size.width / 2 - 20, y: bar.maxY + 30).transition(.opacity)
                }
                ZStack {
                    step(size: size, bar: bar)
                        // Suppress the controls' own animations inside the step, keeping its outer crossfade.
                        .transaction { motion.suppressMovement(in: &$0) }
                        .id(session.step)
                        .transition(motion.stepTransition(delay: 0))
                }
                if Self.choosing.contains(session.step) {
                    toolbar.position(x: size.width / 2, y: size.height - dock - 74).transition(.opacity)
                }
                GlassCloseButton(title: "Skip setup", action: skip)
                    .background(.black.opacity(0.3), in: Circle())
                    .position(x: size.width - 38, y: max(bar.maxY, currentMenuBarHeight) + 38)
                    .opacity(covering && fixedDate == nil ? 0 : 1)
                    .animation(.easeOut(duration: 0.4), value: covering)
            }
            .disabled(confirmingSkip || session.applicationMove.isBusy || session.review != nil)
            if let review = session.review {
                suggestionReview(review).transition(.opacity)
            }
            if confirmingSkip {
                skipConfirmation.transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.2), value: confirmingSkip)
        .animation(.easeOut(duration: 0.2), value: session.review == nil)
        // The bar moves when macOS hides or shows its menu bar, which the screen's parameters announce a moment after
        // setup's own change lands.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            currentMenuBarHeight = menuBarHeight()
        }
        .onChange(of: session.menuBarHides) { currentMenuBarHeight = menuBarHeight() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshAccess()
            // Back from System Settings, the stage covers the bar again.
            if session.step == .menuBar && departure == nil { raise() }
        }
        .onChange(of: session.readyToLand) {
            if session.readyToLand && session.step == .menuBar && departure == nil { land() }
        }
        .onChange(of: session.review == nil) { if session.review != nil { showsSuggestions = false } }
        .task {
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.8 : 1.9))
            covering = false
            if session.step == .menuBar && departure == nil { raise() }
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.4 : 1.7))
            intro = false
        }
        .task {
            while !Task.isCancelled {
                session.pollAccessibility()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task {
            await session.loadStoreWidgets()
            await session.loadSuggestions()
        }
        .task {
            let choices = session.themes
            let directory = session.store.configurationStore.themesDirectory
            previews = await Task.detached {
                Dictionary(uniqueKeysWithValues: choices.compactMap { choice in
                    (try? ThemePreview(choice: choice, themesDirectory: directory)).map { (choice.key, $0) }
                })
            }.value
        }
    }

    private func interpolate(_ from: CGRect, _ to: CGRect, _ fraction: Double) -> CGRect {
        CGRect(x: from.minX + (to.minX - from.minX) * fraction, y: from.minY + (to.minY - from.minY) * fraction,
               width: from.width + (to.width - from.width) * fraction, height: from.height + (to.height - from.height) * fraction)
    }

    /// The bar flies from the stage to its place, where the bar itself takes over from its copy.
    private func land() {
        raise()
        departure = .now
        Task {
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.3 : 1))
            reveal()
            withAnimation(motion.stepAnimation) { session.step = .widgets }
            try? await Task.sleep(for: .seconds(0.6))
            landed = true
        }
    }

    /// The person's desktop goes dark from its edges in, as the lights do in a cinema.
    private func dim(size: CGSize, t: Double) -> some View {
        let dark = reduceMotion ? progress(t, 0, 0.4) : UnitCurve.easeInOut.value(at: progress(t, 0, 0.8))
        let reach = hypot(size.width, size.height) / 2
        return ZStack {
            if !reduceMotion {
                RadialGradient(colors: [.clear, .black], center: .center, startRadius: reach * (1 - dark), endRadius: reach * (1.6 - dark))
            }
            Color.black.opacity(0.94 * (reduceMotion ? dark : UnitCurve.easeIn.value(at: progress(t, 0.25, 0.55))))
        }
        .accessibilityHidden(true)
    }

    /// A spark in the dark stretches into a glowing line, which opens on the wallpaper: blurred and shaded behind the
    /// tour but sharp under the bar, and sharp everywhere once the bar is set.
    private func background(size: CGSize, window: CGRect, corner: Double, t: Double) -> some View {
        let open = reduceMotion ? 1 : UnitCurve.easeInOut.value(at: progress(t, 1.0, 1.1))
        let line = UnitCurve.easeOut.value(at: progress(t, 0.7, 0.6))
        let spark = progress(t, 0.6, 0.25) * (1 - progress(t, 1.2, 0.6))
        let home = size.height * 0.45
        let settled = [.tune, .done].contains(session.step)
        let glow = LinearGradient(colors: [.clear, .orange, Self.warm, .orange, .clear], startPoint: .leading, endPoint: .trailing)
        return ZStack {
            ZStack {
                SampleWallpaper()
                ZStack {
                    SampleWallpaper().blur(radius: 40, opaque: true)
                    Color.black.opacity(0.35)
                }
                .opacity(settled ? 0 : 1)
                .mask {
                    Rectangle()
                        .overlay {
                            RoundedRectangle(cornerRadius: corner)
                                .frame(width: window.width, height: window.height)
                                .position(x: window.midX, y: window.midY)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
                .animation(motion.movement(.smooth(duration: 0.7)) ?? .easeOut(duration: 0.3), value: settled)
            }
            .environment(\.colorScheme, macScheme)
            .scaleEffect(1.12 - 0.12 * open)
            .mask {
                Rectangle()
                    .frame(height: size.height * 1.1 * open)
                    .blur(radius: 30 * (1 - open))
                    .position(x: size.width / 2, y: home)
            }
            .opacity(reduceMotion ? progress(t, 0.4, 0.5) : 1)
            if !reduceMotion && open < 1 {
                Ellipse()
                    .fill(RadialGradient(colors: [Self.warm, .orange.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: 70))
                    .frame(width: 140 + 500 * line, height: 140)
                    .blur(radius: 12)
                    .opacity(spark)
                    .position(x: size.width / 2, y: home)
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Rectangle()
                        .fill(glow)
                        .frame(width: size.width * line, height: 2)
                        .background(Rectangle().fill(glow).frame(height: 8).blur(radius: 12))
                        .opacity(1 - open)
                        .position(x: size.width / 2, y: home + side * size.height * 0.55 * open)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityHidden(true)
    }

    /// The bar as it is now, which swells out of the line, waits on the stage and flies to its place.
    private func stageBar(_ frame: CGRect, corner: Double, t: Double, flown: Double) -> some View {
        let swell = reduceMotion ? 1 : t < 1.8 ? 0.08 : Spring(duration: 0.7, bounce: 0.25).value(target: 1.0, time: t - 1.8)
        let staged = 1 - UnitCurve.easeInOut.value(at: progress(flown, 0, 0.9))
        let notch = display.notch.map { $0.upperBound - $0.lowerBound }
        return BarView(store: session.store, display: BarDisplay(id: display.id, isBuiltIn: display.isBuiltIn, isMain: display.isMain,
                                                                 notch: notch.map { (frame.width - $0) / 2...(frame.width + $0) / 2 },
                                                                 isPortrait: display.isPortrait), preview: true)
            .frame(width: frame.width, height: frame.height)
            .environment(\.colorScheme, macScheme)
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(.white.opacity(0.18 * staged), lineWidth: 1))
            .shadow(color: .black.opacity(0.45 * staged), radius: 35, y: 15)
            .scaleEffect(x: 1, y: swell)
            .opacity(reduceMotion ? progress(t, 0.5, 0.5) * (1 - progress(flown, 0, 0.3)) : progress(t, 1.7, 0.1))
            .position(x: frame.midX, y: frame.midY)
            .accessibilityHidden(true)
    }

    /// StableBar's name over the bar, and the one question under it.
    private func ask(size: CGSize, stage: CGRect, t: Double) -> some View {
        let named = reduceMotion ? progress(t, 0.5, 0.5) : UnitCurve.easeOut.value(at: progress(t, 1.9, 0.7))
        let asked = reduceMotion ? progress(t, 0.7, 0.5) : UnitCurve.easeOut.value(at: progress(t, 2.3, 0.6))
        let gleam = reduceMotion ? 1 : progress(t, 2.3, 1.2)
        let wordmark = Text("StableBar").font(.system(size: 76, weight: .bold)).tracking(-2.2)
        let name = session.system.macOSVersion.accessibilityName
        let automation = !session.menuBarHides
        let accessibility = !session.accessibilityAccess
        let asksAgain = session.placementChoice != nil
        return ZStack {
            wordmark
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: Self.warm, location: 0.5), .init(color: .clear, location: 0.6)],
                                   startPoint: UnitPoint(x: 2 * gleam - 1, y: 0), endPoint: UnitPoint(x: 2 * gleam, y: 0))
                        .mask(wordmark)
                }
                .blur(radius: 8 * (1 - named))
                .offset(y: reduceMotion ? 0 : -10 * (1 - named))
                .opacity(named)
                .position(x: size.width / 2, y: stage.minY - 120)
            VStack(spacing: 12) {
                Text("Make it your menu bar.").font(.system(size: 34, weight: .semibold)).tracking(-0.5)
                Text("StableBar takes the top edge, and the macOS menu bar hides until you point at it.")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.62))
                if session.waitingForMenuBarAccess {
                    waiting("macOS is asking to let StableBar control System Events…")
                } else if asksAgain && accessibility {
                    waiting("Allow StableBar in System Settings → Privacy & Security → \(name).")
                    Button("Open System Settings…") {
                        lower()
                        session.store.windowClearance.requestAccess()
                    }
                    .buttonStyle(GlassButtonStyle(selected: false, highlighted: true))
                } else if !asksAgain {
                    Button(action: allow) {
                        Label(automation || accessibility ? "Allow" : "Continue", systemImage: "menubar.rectangle")
                            .frame(minWidth: 132)
                    }
                    .buttonStyle(GlassButtonStyle(selected: true, size: .large))
                    .keyboardShortcut(.defaultAction)
                    .disabled(covering && fixedDate == nil)
                    .padding(.top, 14)
                    if automation || accessibility {
                        Text(automation && accessibility ? "macOS asks for Automation to hide its menu bar, then for \(name)."
                             : automation ? "macOS asks for Automation to hide its menu bar."
                             : "macOS asks for \(name), which opens menus and keeps windows clear.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                if session.placementAwaitingAccess != nil {
                    belowMenuBarNotice
                }
                if let error = session.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 560)
            .blur(radius: 6 * (1 - asked))
            .offset(y: reduceMotion ? 0 : 12 * (1 - asked))
            .opacity(asked)
            .frame(height: size.height - stage.maxY - 70, alignment: .top)
            .position(x: size.width / 2, y: stage.maxY + 70 + (size.height - stage.maxY - 70) / 2)
        }
    }

    /// Allow asks macOS for Automation, which hides the menu bar, then for Accessibility in System Settings.
    private func allow() {
        Task {
            await session.place(.top)
            guard !session.accessibilityAccess else { return }
            lower()
            session.store.windowClearance.requestAccess()
        }
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.top, 14)
    }

    private var belowMenuBarNotice: some View {
        Text("StableBar sits below the menu bar, since macOS didn't allow Automation. Change it later in Settings.")
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A warm line that spreads under the bar as it lands, and stays while the bar changes with each choice.
    private func glowLine(width: Double, flight: Double, flown: Double) -> some View {
        let glow = LinearGradient(colors: [.clear, .orange, Self.warm, .orange, .clear], startPoint: .leading, endPoint: .trailing)
        let spread = reduceMotion || session.step != .menuBar && departure == nil ? 1 : UnitCurve.easeOut.value(at: progress(flown, 0.7, 0.8))
        let shown = [.widgets, .look].contains(session.step) || (session.step == .menuBar && flight > 0.7)
        return Rectangle()
            .fill(glow)
            .frame(width: width * spread, height: 2)
            .background(Rectangle().fill(glow).frame(height: 8).blur(radius: 12))
            .opacity(shown ? 0.85 : 0)
            .animation(.easeOut(duration: 0.4), value: shown)
            .accessibilityHidden(true)
    }

    private var live: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.up.left").font(.system(size: 17, weight: .medium))
            Text("Live on your bar").font(Self.handwriting)
        }
        .foregroundStyle(Self.ink)
    }

    @ViewBuilder private func step(size: CGSize, bar: CGRect) -> some View {
        switch session.step {
        case .menuBar: Color.clear
        case .widgets: presets(top: bar.maxY + 80)
        case .look: looks(size: size, top: bar.maxY + 80)
        case .tune: tune.padding(.top, bar.maxY + 22).frame(maxHeight: .infinity, alignment: .top)
        case .done: done.position(x: size.width / 2, y: size.height * 0.42)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 42, weight: .semibold)).tracking(-0.8)
    }

    private func presets(top: Double) -> some View {
        VStack(spacing: 34) {
            title("What's your bar for?")
            VStack(spacing: 9) {
                ForEach(SetupPreferences.Preset.allCases, id: \.self) { preset in
                    let store = session.widgetSets(preset).filter { if case .store = $0 { true } else { false } }.count
                    SetupTile(selected: session.preset == preset) {
                        Task {
                            await session.loadStoreWidgets()
                            session.toggle(preset)
                        }
                    } label: {
                        HStack(spacing: 18) {
                            HStack(spacing: 8) {
                                Text(preset.title).font(.system(size: 16, weight: .semibold))
                                if store > 0 {
                                    Text("\(store) Store")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Self.warm)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Self.warm.opacity(0.14), in: Capsule())
                                }
                            }
                            .frame(width: 200, alignment: .leading)
                            presetBar(preset)
                        }
                        .padding(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 12))
                    }
                    .accessibilityLabel(preset.accessibilityLabel(widgetSets: session.widgetSets(preset)))
                }
            }
            .frame(width: 840)
        }
        .padding(.top, top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The right end of the bar `preset` gives, in the selected theme, at a size its widgets can be told apart.
    private func presetBar(_ preset: SetupPreferences.Preset) -> some View {
        GeometryReader { proxy in
            if let preview = previews[session.store.configurationStore.selectedThemeKey] {
                let look = preview.configuration(for: barAppearance)
                ThemeSampleBar(look: look, widgets: session.sampleWidgets(preset, tokens: preview.tokens))
                    .frame(width: proxy.size.width / 0.64, height: 76)
                    .offset(y: -(76 - look.bar.height) / 2)
                    .scaleEffect(0.64, anchor: .topTrailing)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
            }
        }
        .frame(height: 58)
        .background(SampleWallpaper())
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, barAppearance.colorScheme)
        .accessibilityHidden(true)
    }

    private func looks(size: CGSize, top: Double) -> some View {
        let choices = session.themes
        let selected = choices.firstIndex { $0.key == session.store.configurationStore.selectedThemeKey } ?? 0
        return VStack(spacing: 64) {
            title("Pick a look.")
            ZStack {
                ForEach(choices.indices, id: \.self) { index in
                    let offset = index - selected
                    themeCard(choices[index], size: size, selected: offset == 0)
                        .scaleEffect(offset == 0 ? 1 : 0.74)
                        .offset(x: Double(offset) * 470)
                        .opacity(abs(offset) > 2 ? 0 : offset == 0 ? 1 : 0.5)
                        .zIndex(Double(10 - abs(offset)))
                        .allowsHitTesting(abs(offset) <= 1)
                        .accessibilityHidden(abs(offset) > 2)
                }
                HStack {
                    arrow("chevron.left", label: "Previous theme", key: .leftArrow) { choose(choices[(selected + choices.count - 1) % choices.count]) }
                    Spacer()
                    arrow("chevron.right", label: "Next theme", key: .rightArrow) { choose(choices[(selected + 1) % choices.count]) }
                }
                .frame(width: size.width - 660)
                .offset(y: -32)
                .zIndex(20)
            }
            .frame(height: 300, alignment: .top)
            .animation(motion.movement(.spring(duration: 0.6, bounce: 0.25)), value: selected)
        }
        .padding(.top, top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// A card with the top right corner of the screen: the wallpaper and the bar in `choice`'s look.
    private func themeCard(_ choice: ThemeChoice, size: CGSize, selected: Bool) -> some View {
        Button { choose(choice) } label: {
            VStack(spacing: 16) {
                ZStack(alignment: .topTrailing) {
                    SampleWallpaper().frame(width: size.width, height: size.height)
                    if let preview = previews[choice.key] {
                        let look = preview.configuration(for: barAppearance)
                        ThemeSampleBar(look: look, widgets: session.preset.map { session.sampleWidgets($0, tokens: preview.tokens) })
                            .frame(width: size.width, height: 76)
                            .offset(y: -(76 - look.bar.height) / 2)
                    }
                }
                .frame(width: 600, height: 230, alignment: .topTrailing)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .environment(\.colorScheme, barAppearance.colorScheme)
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(selected ? 1 : 0.24), lineWidth: selected ? 2.5 : 0.5))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
                HStack(spacing: 8) {
                    Text(choice.title).font(.system(size: 22, weight: .semibold))
                    if choice.key == session.currentThemeKey {
                        Text("Current").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel("\(choice.title) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func arrow(_ symbol: String, label: String, key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: 36)
        }
        .buttonStyle(GlassButtonStyle(selected: false, round: true))
        .glass(Circle())
        .keyboardShortcut(key, modifiers: [])
        .help(label)
        .accessibilityLabel(label)
    }

    private func choose(_ choice: ThemeChoice) {
        session.preferences.theme = choice.key == session.currentThemeKey ? .current
            : .package(id: choice.manifest.id, version: choice.isBundled ? nil : choice.manifest.version)
    }

    /// What's left for the bar the person chose, in a panel that hangs from it.
    private var tune: some View {
        let toAdd = session.storeWidgetsToAdd.map(\.entry.name)
        let added = session.preferences.widgetSets.compactMap { set -> String? in
            guard case let .store(id, name, _, _) = set, session.preferences.storeWidgets.contains(where: { $0.id == id }) else { return nil }
            return name
        }
        let leftOut = session.preset.map(session.leftOut) ?? []
        let calendars = session.needsCalendarAccess || session.preferences.widgetSets.contains(.meetings)
        let shortcuts = session.showsSpacesGuidance
        let empty = toAdd.isEmpty && added.isEmpty && leftOut.isEmpty && !calendars && !shortcuts && session.suggestions.isEmpty
            && session.placementAwaitingAccess == nil
        return VStack(alignment: .leading, spacing: 14) {
            Text("Finishing touches.").font(.system(size: 19, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                if !leftOut.isEmpty, let preset = session.preset {
                    GridRow {
                        label("Store")
                        Text("The Store can't be reached, so \(preset.title) leaves out \(ListFormatter.localizedString(byJoining: leftOut)).")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.62))
                    }
                } else if !toAdd.isEmpty || !added.isEmpty {
                    GridRow {
                        label("Store")
                        HStack(spacing: 10) {
                            if toAdd.isEmpty {
                                Label("\(ListFormatter.localizedString(byJoining: added)) added.", systemImage: "checkmark")
                                    .foregroundStyle(Self.allowed)
                            } else {
                                Text("\(ListFormatter.localizedString(byJoining: toAdd)) \(toAdd.count == 1 ? "runs" : "run") commands from the Store.")
                                    .foregroundStyle(.white.opacity(0.62))
                                if session.downloading != nil && session.review == nil {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button { Task { await session.reviewStoreWidgets() } } label: { Label("Add", systemImage: "plus") }
                                        .buttonStyle(GlassButtonStyle(selected: true, size: .compact))
                                        .accessibilityLabel("Add \(ListFormatter.localizedString(byJoining: toAdd))")
                                }
                            }
                        }
                        .font(.system(size: 13))
                    }
                }
                if calendars || shortcuts {
                    GridRow {
                        label("Needs")
                        HStack(spacing: 8) {
                            if calendars { calendarChip }
                            if shortcuts { shortcutsChip }
                        }
                    }
                }
            }
            if session.placementAwaitingAccess != nil { belowMenuBarNotice }
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if empty {
                Text("Your bar has everything it needs.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.62))
            }
            if !session.suggestions.isEmpty {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
                suggestionsPill
            }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        .frame(width: 820, alignment: .leading)
        .background(Self.panel, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.24), lineWidth: 0.5))
        .overlay(alignment: .top) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 8))
                path.addLine(to: CGPoint(x: 8, y: 0))
                path.addLine(to: CGPoint(x: 16, y: 8))
            }
            .fill(Self.panel)
            .frame(width: 16, height: 8)
            .offset(y: -8)
        }
        .shadow(color: .black.opacity(0.4), radius: 35, y: 15)
        .onAppear { session.store.workspaceStore.refreshDesktopShortcuts() }
    }

    private static let allowed = Color(red: 0.557, green: 0.941, blue: 0.659)

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.62)).frame(width: 66, alignment: .leading)
    }

    private func chip<Content: View>(done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.leading, 12)
            .padding(.trailing, done ? 12 : 4)
            .frame(height: 34)
            .background(done ? Color(red: 0.204, green: 0.78, blue: 0.349).opacity(0.18) : .white.opacity(0.1), in: Capsule(style: .circular))
            .overlay(Capsule(style: .circular).strokeBorder(.white.opacity(0.24), lineWidth: 0.5))
    }

    /// Calendars for Meetings, which can wait: Later saves Meetings turned off.
    @ViewBuilder private var calendarChip: some View {
        let title = SetupPermission.calendars.title(on: session.system.macOSVersion)
        if session.calendarAccess == .fullAccess {
            chip(done: true) { Label(title, systemImage: "checkmark").foregroundStyle(Self.allowed) }
        } else if session.preferences.deferMeetings {
            chip(done: false) {
                Text(title)
                Text("later").fontWeight(.regular).foregroundStyle(.white.opacity(0.4))
                linkButton("Undo") { session.preferences.deferMeetings = false }.padding(.trailing, 8)
            }
        } else {
            chip(done: false) {
                Label(title, systemImage: "calendar")
                if session.needsCalendarSetup {
                    linkButton("Later") { session.preferences.deferMeetings = true }
                        .accessibilityLabel("Set up Meetings later")
                }
                if session.calendarAccess == .notDetermined {
                    permissionButton(.allow, for: .calendars) { Task { await session.requestCalendarAccess() } }
                } else {
                    permissionButton(.openSettings, for: .calendars) {
                        lower()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
            }
        }
    }

    /// The Switch to Desktop shortcuts Workspaces uses on macOS Spaces. Setup finishes without them.
    @ViewBuilder private var shortcutsChip: some View {
        let status = session.store.workspaceStore.desktopShortcutStatus
        if status.allEnabled {
            chip(done: true) { Label(DesktopShortcuts.title, systemImage: "checkmark").foregroundStyle(Self.allowed) }
        } else {
            chip(done: false) {
                Label(DesktopShortcuts.title, systemImage: "keyboard")
                Text("Optional").fontWeight(.regular).foregroundStyle(.white.opacity(0.4))
                Button(DesktopShortcuts.actionTitle) {
                    lower()
                    do { try DesktopShortcuts.openSettings() }
                    catch { session.error = errorMessage(error) }
                }
                .buttonStyle(GlassButtonStyle(selected: false, highlighted: true, size: .compact))
            }
            .help(status.detail)
            .accessibilityHint(status.detail)
        }
    }

    private func permissionButton(_ kind: SetupPermission.Action, for permission: SetupPermission, action: @escaping () -> Void) -> some View {
        let label = kind.accessibilityLabel(for: permission, on: session.system.macOSVersion)
        return Button(kind.title, action: action)
            .buttonStyle(GlassButtonStyle(selected: true, size: .compact))
            .accessibilityLabel(label)
            .accessibilityInputLabels([Text(kind.title), Text(label)])
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .underline()
            .foregroundStyle(.white.opacity(0.62))
    }

    /// Store packages for tools found on this Mac. They run commands, so adding one opens its review first.
    private var suggestionsPill: some View {
        Button { showsSuggestions.toggle() } label: {
            GlassPill {
                HStack(spacing: 7) {
                    Text("Found on your Mac")
                    Text("\(session.suggestions.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(.white.opacity(0.22), in: Capsule())
                }
            }
            .overlay(Capsule(style: .circular).strokeBorder(Self.gold.opacity(0.55), lineWidth: 2).padding(-2))
            .shadow(color: Self.gold.opacity(0.35), radius: 7)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsSuggestions, arrowEdge: .bottom) { suggestionList }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Store widgets for tools on this Mac. Nothing downloads until you add one.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(EdgeInsets(top: 6, leading: 10, bottom: 8, trailing: 10))
            ForEach(session.suggestions, id: \.key) { entry in
                let added = session.preferences.packages.contains { $0.id == entry.id }
                HStack(spacing: 10) {
                    Image(systemName: entry.symbol ?? "shippingbox")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.system(size: 13.5, weight: .semibold))
                        if let description = entry.description {
                            Text(description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if session.downloading == entry.key {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await session.pick(entry) } } label: {
                            Label(added ? "Added" : "Add", systemImage: added ? "checkmark" : "plus")
                        }
                        .buttonStyle(GlassButtonStyle(selected: !added, highlighted: added, size: .compact))
                        .accessibilityLabel(added ? "Remove \(entry.name)" : "Add \(entry.name)")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .padding(8)
        .frame(width: 400)
        .disabled(session.downloading != nil)
        .environment(\.colorScheme, .dark)
    }

    /// The review Add here shows, for a suggestion picked under Found on your Mac or a preset's Store widget.
    private func suggestionReview(_ review: (inspection: WidgetPackageInspection, sourceID: String, settings: [String: ConfigurationValue]?)) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(alignment: .leading, spacing: 10) {
                PackagesView(store: session.store, reviewing: review.inspection, reviewingSourceID: review.sourceID,
                             reviewingSettings: review.settings,
                             onEnable: { session.add($0, settings: $1) }, onAdded: { Task { await session.endReview() } },
                             onWorkingChanged: { reviewIsWorking = $0 })
                    // A preset's next Store widget opens a review of its own.
                    .id(review.inspection.manifest.versionKey)
                Button("Back") { Task { await session.endReview() } }
                    .buttonStyle(GlassButtonStyle(selected: false, highlighted: true))
                    .keyboardShortcut(.cancelAction)
                    .disabled(reviewIsWorking)
            }
            .padding(14)
            .frame(width: 540, height: 540)
            .background(Self.panel, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.24), lineWidth: 0.5))
        }
    }

    private var done: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(SettingsPalette.success, in: Circle())
                        .overlay(Circle().strokeBorder(Color(white: 0.16), lineWidth: 3))
                        .offset(x: 6, y: 6)
                }
                .accessibilityHidden(true)
                .padding(.bottom, 14)
            Text("You're all set.").font(.system(size: 28, weight: .semibold)).padding(.bottom, 6)
            Text("Click a widget to open it. Right-click the bar to edit it in place, try themes or open Settings.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)
            VStack(spacing: 10) {
                if session.preferences.widgetSets.contains(.meetings) && session.preferences.deferMeetings {
                    Label("Meetings stays off. Turn it on in Settings → Bar when you're ready to allow Calendar access.", systemImage: "calendar")
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                login
                if session.finished && session.loginStatus == .requiresApproval {
                    Text("Open at login still needs your approval in macOS.").font(.system(size: 12.5))
                    Button("Allow StableBar in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(GlassButtonStyle(selected: false, highlighted: true, size: .compact))
                }
                if let error = session.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 16)
            HStack(spacing: 8) {
                if let editBar {
                    Button("Edit Bar in Place") { finish(then: editBar) }
                        .buttonStyle(GlassButtonStyle(selected: false, highlighted: true))
                }
                Button { finish() } label: {
                    HStack(spacing: 7) {
                        Text("Done")
                        Image(systemName: "checkmark")
                    }
                }
                .buttonStyle(GlassButtonStyle(selected: true))
                .keyboardShortcut(.defaultAction)
            }
            .disabled(session.applicationMove.isBusy)
        }
        .padding(EdgeInsets(top: 30, leading: 30, bottom: 22, trailing: 30))
        .frame(width: 480)
        .background(Self.panel, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.24), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 40, y: 15)
    }

    /// Open at login, which only works from an Applications folder; elsewhere, the move there.
    private var login: some View {
        let inApplications = session.system.isInApplications()
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Open at login").font(.system(size: 13.5, weight: .semibold))
                Text(inApplications ? "Starts StableBar when you log in." : "Move StableBar to Applications to start it at login.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
            }
            Spacer(minLength: 12)
            if inApplications {
                Toggle("Open at login", isOn: Binding(get: { session.opensAtLogin }, set: { session.openAtLogin = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(session.finished)
            } else {
                ApplicationMoveControls(controller: session.applicationMove, resume: session.resumeAfterMoving, reveal: lower, setup: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Saves the bar and closes setup, or keeps it open while Open at login waits for approval in macOS.
    private func finish(then next: (() -> Void)? = nil) {
        if !session.finished {
            session.finish()
            guard session.finished, session.loginStatus != .requiresApproval else { return }
        }
        close()
        next?()
    }

    private var toolbar: some View {
        let index = Self.choosing.firstIndex(of: session.step) ?? 0
        return HStack(spacing: 2) {
            // The bar has already taken its place, so the first choice has nothing to go back to.
            if index > 0 {
                Button {
                    withAnimation(motion.stepAnimation) { session.step = Self.choosing[index - 1] }
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)).frame(width: 36)
                }
                .buttonStyle(GlassButtonStyle(selected: false, round: true))
                .accessibilityLabel("Back")
            }
            HStack(spacing: 6) {
                ForEach(Self.choosing.indices, id: \.self) { dot in
                    Capsule().fill(.white.opacity(dot == index ? 1 : 0.35)).frame(width: dot == index ? 18 : 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .animation(motion.movement(.spring(duration: 0.4, bounce: 0.3)), value: index)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(index + 1) of \(Self.choosing.count)")
            Button {
                withAnimation(motion.stepAnimation) { session.step = index + 1 < Self.choosing.count ? Self.choosing[index + 1] : .done }
            } label: {
                HStack(spacing: 7) {
                    Text("Continue")
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(GlassButtonStyle(selected: true))
            .keyboardShortcut(.defaultAction)
            .disabled(session.step == .tune && !session.missingPermissions.isEmpty)
        }
        .padding(4)
        .background(.black.opacity(0.3), in: Capsule())
        .glass(Capsule(style: .circular))
        .fixedSize()
    }

    private func skip() {
        if session.finished || !session.hasChanges { close() } else { confirmingSkip = true }
    }

    /// Asks before Skip setup, or Esc, throws away the choices made so far.
    private var skipConfirmation: some View {
        ZStack {
            Color.black.opacity(0.4)
                .contentShape(Rectangle())
                .onTapGesture { confirmingSkip = false }
            VStack(spacing: 6) {
                Text("Skip setup?").font(.system(size: 20, weight: .semibold))
                Text("""
                    Your bar goes back to how it was\(session.changedMenuBar ? ", and so does the macOS menu bar" : ""), and nothing is saved. \
                    Open setup again with Getting Started… in the menu-bar icon's menu.
                    """)
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
                HStack(spacing: 8) {
                    Button("Skip Setup") {
                        confirmingSkip = false
                        close()
                    }
                    .buttonStyle(GlassButtonStyle(selected: false, highlighted: true))
                    Button("Keep Setting Up") { confirmingSkip = false }
                        .buttonStyle(GlassButtonStyle(selected: true))
                        .keyboardShortcut(.defaultAction)
                }
                // Esc keeps setting up while the question shows.
                Button("") { confirmingSkip = false }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13))
            .padding(22)
            .frame(width: 360)
            .background(Self.panel, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.24), lineWidth: 0.5))
        }
    }
}

/// How far `time` is through the span that begins at `start` and lasts `duration`, from 0 to 1.
func progress(_ time: Double, _ start: Double, _ duration: Double) -> Double {
    min(max((time - start) / duration, 0), 1)
}

/// Shantell Sans from the app's resources, or the system font outside the app bundle, as when tests draw setup.
func shantellSans(_ file: String, size: Double) -> CTFont {
    guard let url = Bundle.main.url(forResource: file, withExtension: "woff2"),
          let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first else {
        return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
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
                .background(.white.opacity(selected ? 0.16 : hovering ? 0.13 : 0.08), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(selected ? 1 : 0.24), lineWidth: selected ? 2.5 : 0.5))
                .shadow(color: .black.opacity(selected ? 0.3 : 0), radius: 15, y: 10)
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 16))
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
