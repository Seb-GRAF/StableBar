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
    /// The tour's backdrop, made from `wallpaper` when StableBar can read it.
    let backdrop: SetupBackdrop
    let wallpaper: URL?
    /// Closes setup, once it's finished or to skip it.
    let close: () -> Void
    /// Puts the tour under the macOS menu bar but over the bar, under the bar once it's in place, or under System
    /// Settings. The intro covers the menu bar too.
    let raise: () -> Void
    let reveal: () -> Void
    let lower: () -> Void
    let editBar: (() -> Void)?
    /// When the intro started, once the backdrop was ready.
    @State private var opened: Date?
    /// Whether the intro has played to its end or been skipped.
    @State private var settled: Bool
    /// Whether the tour still covers the macOS menu bar, which would hide macOS's own prompts.
    @State private var covering: Bool
    /// Whether the bar has flown to its place, after Finish setup.
    @State private var landed: Bool
    @State private var previews: [String: ThemePreview] = [:]
    @State private var confirmingSkip = false
    @State private var reviewIsWorking = false
    @State private var showsSuggestions = false
    /// The height of Allow's card, which centers Allow on the screen with the bar above it.
    @State private var allowCardHeight = 300.0
    /// The menu bar's height as last read, so the bar's place follows it when the menu bar hides or shows.
    @State private var currentMenuBarHeight: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The date scenes draw at, which shows every animation finished.
    @Environment(\.fixedDate) private var fixedDate
    @Environment(\.offscreenSnapshot) private var offscreen
    @Environment(\.sceneWallpaper) private var sceneWallpaper
    @Environment(\.displayScale) private var displayScale

    private var motion: SetupMotion { SetupMotion(reduceMotion: reduceMotion) }
    private static let ink = Color(red: 0.949, green: 0.933, blue: 1)
    private static let warm = Color(red: 1, green: 0.8, blue: 0.45)
    private static let gold = Color(red: 0.847, green: 0.698, blue: 0.369)
    private static let allowed = Color(red: 0.557, green: 0.941, blue: 0.659)
    private static let panel = Color(red: 0.11, green: 0.11, blue: 0.125).opacity(0.9)
    private static let handwriting = Font(shantellSans("shantell-sans-hand", size: 22))
    /// Dims the wallpaper behind the tour, a little blue so a light wallpaper doesn't turn grey.
    private static let shade = Color(red: 0.05, green: 0.04, blue: 0.16)
    private static let glow = LinearGradient(colors: [.clear, .orange, warm, .orange, .clear], startPoint: .leading, endPoint: .trailing)

    init(session: SetupSession, display: BarDisplay, menuBarHeight: @escaping () -> Double, dock: Double, backdrop: SetupBackdrop,
         wallpaper: URL?, close: @escaping () -> Void, raise: @escaping () -> Void, reveal: @escaping () -> Void,
         lower: @escaping () -> Void, editBar: (() -> Void)?) {
        _session = Bindable(session)
        self.display = display
        self.menuBarHeight = menuBarHeight
        _currentMenuBarHeight = State(initialValue: menuBarHeight())
        self.dock = dock
        self.backdrop = backdrop
        self.wallpaper = wallpaper
        self.close = close
        self.raise = raise
        self.reveal = reveal
        self.lower = lower
        self.editBar = editBar
        _settled = State(initialValue: session.step != .intro)
        _covering = State(initialValue: session.step == .intro)
        _landed = State(initialValue: session.step == .done)
    }

    /// Where the bar sits on a display of `size`, measured down from its top.
    private func barFrame(in size: CGSize) -> CGRect {
        guard let configuration = session.store.configuration else { return .zero }
        let frame = configuration.onScreen(ScreenKind(display)).bar.frame(height: configuration.barGeometry(for: display).layoutHeight,
                                                                           on: CGRect(origin: .zero, size: size), menuBar: currentMenuBarHeight)
        return CGRect(x: 0, y: size.height - frame.maxY, width: size.width, height: frame.height)
    }

    /// The width the bar is laid out at on the stage.
    private func stageWidth(_ size: CGSize) -> Double { min(size.width - 112, 1400) }

    /// What the tour leaves free at the top: the macOS menu bar, once the intro stops covering it.
    private var top: Double { covering ? 0 : currentMenuBarHeight }

    /// The top of a group `height` high, a little above the middle of the space between the menu bar and the toolbar.
    private func groupTop(_ size: CGSize, height: Double) -> Double {
        top + max(24, (size.height - dock - 96 - top - height) * 0.44)
    }

    /// The tops of Make it yours' title, presets and themes, and the middle of the bar between the title and the
    /// presets.
    private func chooseLayout(_ size: CGSize, bar: Double) -> (title: Double, bar: Double, presets: Double, themes: Double) {
        let title = groupTop(size, height: 78 + 48 + bar + 52 + 98 + 30 + 114)
        let presets = title + 78 + 48 + bar + 52
        return (title, title + 126 + bar / 2, presets, presets + 98 + 30)
    }

    /// The tops of Allow's title and card, and the middle of the bar between them, smaller than on Make it yours.
    private func allowLayout(_ size: CGSize, bar: Double) -> (title: Double, bar: Double, card: Double) {
        let title = groupTop(size, height: 84 + bar * 0.68 + 36 + allowCardHeight)
        return (title, title + 84 + bar * 0.68 / 2, title + 84 + bar * 0.68 + 36)
    }

    /// Where the bar sits on each step: its middle, the width it's laid out at, and its scale.
    private func pose(in size: CGSize, bar: CGRect) -> (center: CGPoint, width: Double, scale: Double) {
        switch session.step {
        case .intro: (CGPoint(x: size.width / 2, y: size.height * 0.5), stageWidth(size), 0.72)
        case .choose: (CGPoint(x: size.width / 2, y: chooseLayout(size, bar: bar.height).bar), stageWidth(size), 1)
        case .allow: (CGPoint(x: size.width / 2, y: allowLayout(size, bar: bar.height).bar), stageWidth(size), 0.68)
        case .done: (CGPoint(x: bar.midX, y: bar.midY), size.width, 1)
        }
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
            TimelineView(.animation(paused: fixedDate != nil || session.step != .intro || settled || opened == nil)) { context in
                let intro = SetupIntro(reduceMotion: reduceMotion,
                                       time: fixedDate != nil || settled ? 60 : opened.map { context.date.timeIntervalSince($0) } ?? 0)
                ZStack {
                    background(size: size, intro: intro)
                    if session.step == .intro {
                        introduction(size: size, intro: intro)
                    }
                    if !landed {
                        stageBar(size: size, bar: bar, intro: intro)
                    }
                    if session.step == .done {
                        Rectangle()
                            .fill(Self.glow)
                            .frame(width: size.width * (landed || reduceMotion ? 1 : 0), height: 2)
                            .background(Rectangle().fill(Self.glow).frame(height: 8).blur(radius: 12))
                            .opacity(landed ? 0.85 : 0)
                            .position(x: size.width / 2, y: bar.maxY)
                            .accessibilityHidden(true)
                    }
                }
            }
            ZStack {
                if session.step == .choose {
                    choose(size: size, bar: bar)
                }
                if session.step == .allow {
                    allow(size: size, bar: bar)
                }
                if session.step == .done && landed {
                    done
                        .position(x: size.width / 2, y: size.height * 0.42)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -16)).combined(with: .scale(scale: 0.94, anchor: .top)))
                }
                if [.choose, .allow].contains(session.step) {
                    toolbar.position(x: size.width / 2, y: size.height - dock - 74).transition(.opacity)
                }
                GlassCloseButton(title: "Skip setup", action: skip)
                    .background(.black.opacity(0.3), in: Circle())
                    .position(x: size.width - 38, y: max(top, session.step == .done ? bar.maxY : 0) + 38)
                    .opacity(session.step == .intro && !settled && fixedDate == nil ? 0 : 1)
                    .animation(.easeOut(duration: 0.4), value: settled)
            }
            .disabled(confirmingSkip || session.applicationMove.isBusy || session.review != nil)
            if let review = session.review {
                suggestionReview(review).transition(.opacity)
            }
            if confirmingSkip {
                skipConfirmation.transition(.opacity)
            }
            Color.clear
                .task(id: macScheme) {
                    let scene = sceneWallpaper?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    await backdrop.load(offscreen ? scene.map(SetupBackdrop.Wallpaper.image) : wallpaper.map(SetupBackdrop.Wallpaper.file),
                                        pixels: CGSize(width: size.width * displayScale, height: size.height * displayScale), dark: macScheme == .dark)
                    guard opened == nil else { return }
                    opened = .now
                    try? await Task.sleep(for: .seconds(SetupIntro(reduceMotion: reduceMotion, time: 0).length))
                    settled = true
                }
                .allowsHitTesting(false)
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
            // Back from System Settings, the tour covers the bar again.
            if [.choose, .allow].contains(session.step) { raise() }
        }
        .onChange(of: session.review == nil) { if session.review != nil { showsSuggestions = false } }
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

    /// The wallpaper, sharp as it fades in and settles, then soft and dimmed behind the tour, gone once the bar is in
    /// its place.
    private func background(size: CGSize, intro: SetupIntro) -> some View {
        ZStack {
            if let images = backdrop.images {
                Image(decorative: images.sharp, scale: 1).resizable().opacity(intro.wallpaper)
                Image(decorative: images.soft, scale: 1).resizable().interpolation(.high).opacity(intro.softness)
                Self.shade.opacity(0.4 * intro.softness)
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(intro.zoom)
        .opacity(session.step == .done ? 0 : 1)
        .clipped()
        .accessibilityHidden(true)
    }

    /// StableBar's name over the bar, and what it is under it, with Get Started. A click or Return during the intro
    /// skips to its end.
    private func introduction(size: CGSize, intro: SetupIntro) -> some View {
        let center = pose(in: size, bar: barFrame(in: size)).center
        let wordmark = Text("StableBar").font(.system(size: 76, weight: .bold)).tracking(-2.2)
        return ZStack {
            if !settled {
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: settle)
            }
            wordmark
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: Self.warm, location: 0.5), .init(color: .clear, location: 0.6)],
                                   startPoint: UnitPoint(x: 2 * intro.sweep - 1, y: 0), endPoint: UnitPoint(x: 2 * intro.sweep, y: 0))
                        .mask(wordmark)
                        .opacity(intro.sweep > 0 && intro.sweep < 1 ? 1 : 0)
                }
                .offset(y: intro.nameRise)
                .opacity(intro.name)
                .position(x: size.width / 2, y: center.y - 112)
            Text("A native, configurable bar for your Mac.")
                .font(Self.handwriting)
                .foregroundStyle(Self.ink)
                .opacity(intro.invitation)
                .offset(y: reduceMotion ? 0 : 8 * (1 - intro.invitation))
                .position(x: size.width / 2, y: center.y + 62)
            Button { if settled { start() } else { settle() } } label: {
                HStack(spacing: 9) {
                    Text("Get Started")
                    Image(systemName: "arrow.right")
                }
                .frame(minWidth: 132)
            }
            .buttonStyle(GlassButtonStyle(selected: true, size: .large))
            .keyboardShortcut(.defaultAction)
            .opacity(intro.invitation)
            .offset(y: reduceMotion ? 0 : 10 * (1 - intro.invitation))
            .position(x: size.width / 2, y: size.height - dock - 150)
        }
        .transition(.opacity.animation(.easeOut(duration: 0.3)))
    }

    private func settle() {
        withAnimation(.easeOut(duration: 0.35)) { settled = true }
    }

    /// Leaves the intro: the bar rises to the stage, and macOS's menu bar shows above the tour, as it will until the bar
    /// takes its place.
    private func start() {
        covering = false
        raise()
        withAnimation(motion.stageAnimation) { session.step = .choose }
    }

    /// The bar as it is now: it opens out of a glowing line in the intro, waits on the stage over the top of the
    /// wallpaper, and flies to its place at the end.
    private func stageBar(size: CGSize, bar: CGRect, intro: SetupIntro) -> some View {
        let pose = pose(in: size, bar: bar)
        let staged = session.step != .done
        let notch = display.notch.map { $0.upperBound - $0.lowerBound }
        return ZStack {
            if session.step == .intro {
                Rectangle()
                    .fill(Self.glow)
                    .frame(width: pose.width * pose.scale * intro.line, height: 2)
                    .background(Rectangle().fill(Self.glow).frame(height: 10).blur(radius: 10))
                    .opacity(intro.glow)
            }
            ZStack {
                if let images = backdrop.images {
                    Image(decorative: images.sharp, scale: 1).resizable().scaledToFill()
                        .frame(width: pose.width, height: bar.height, alignment: .top)
                        .clipped()
                        .opacity(staged ? 1 : 0)
                }
                BarView(store: session.store, display: BarDisplay(id: display.id, isBuiltIn: display.isBuiltIn, isMain: display.isMain,
                                                                  notch: notch.map { (pose.width - $0) / 2...(pose.width + $0) / 2 },
                                                                  isPortrait: display.isPortrait), preview: true)
                    .environment(\.colorScheme, macScheme)
                    .environment(\.sampleAppMenus, session.frontmostApp.map { [$0, "File", "Edit", "View", "Window", "Help"] } ?? [])
                    .mask {
                        LinearGradient(colors: [.black, .clear], startPoint: UnitPoint(x: intro.widgets * 1.25 - 0.25, y: 0),
                                       endPoint: UnitPoint(x: intro.widgets * 1.25, y: 0))
                    }
            }
            .frame(width: pose.width, height: bar.height)
            .clipShape(RoundedRectangle(cornerRadius: staged ? 14 : 0))
            .overlay(RoundedRectangle(cornerRadius: staged ? 14 : 0).strokeBorder(.white.opacity(staged ? 0.18 : 0), lineWidth: 1))
            .shadow(color: .black.opacity(staged ? 0.45 : 0), radius: 35, y: 15)
            .scaleEffect(x: 1, y: intro.open)
            .opacity(intro.bar)
            .scaleEffect(pose.scale)
            // With Reduce Motion, the bar fades out of one place and into the next.
            .id(reduceMotion ? "\(session.step)" : "stage")
        }
        .position(pose.center)
        .accessibilityHidden(true)
    }

    private func title(_ text: String, size: Double = 40) -> some View {
        Text(text).font(.system(size: size, weight: .semibold)).tracking(-0.8)
    }

    private func section(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 11.5, weight: .semibold)).tracking(0.6).foregroundStyle(.white.opacity(0.42))
    }

    /// `content` across the stage's width, its top `y` down the screen.
    private func placed(_ content: some View, y: Double, size: CGSize) -> some View {
        content
            .frame(width: stageWidth(size), alignment: .leading)
            .padding(.top, y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Make it yours: a preset for the bar's widgets and a theme for its look, with the bar between the title and them.
    @ViewBuilder private func choose(size: CGSize, bar: CGRect) -> some View {
        let layout = chooseLayout(size, bar: bar.height)
        VStack(spacing: 10) {
            title("Make it yours.")
            Text("Pick your widgets and a look. Your bar changes as you choose.")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(.top, layout.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(motion.stepTransition(delay: 0))
        placed(VStack(alignment: .leading, spacing: 12) {
            section("Widgets")
            presets(width: stageWidth(size))
        }, y: layout.presets, size: size)
        .transition(motion.stepTransition(delay: 0.06))
        placed(VStack(alignment: .leading, spacing: 12) {
            section("Theme")
            themes(size: size)
        }, y: layout.themes, size: size)
        .transition(motion.stepTransition(delay: 0.12))
        if !session.suggestions.isEmpty {
            suggestionsPill
                .padding(.leading, 24)
                .padding(.top, top + 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(motion.stepTransition(delay: 0.18))
        }
    }

    private func presets(width: Double) -> some View {
        HStack(spacing: 12) {
            ForEach(SetupPreferences.Preset.allCases, id: \.self) { preset in
                let selected = session.preset == preset
                let store = session.widgetSets(preset).contains { if case .store = $0 { true } else { false } }
                SetupTile(selected: selected) {
                    Task {
                        await session.loadStoreWidgets()
                        session.toggle(preset)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: preset.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(selected ? Color.black : Color.white)
                            .frame(width: 38, height: 38)
                            .background(.white.opacity(selected ? 0.92 : 0.1), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(preset.title).font(.system(size: 15, weight: .semibold))
                                if store {
                                    Text("Store")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Self.warm)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(Self.warm.opacity(0.14), in: Capsule())
                                }
                            }
                            Text(preset.summary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 13)
                    .frame(maxWidth: .infinity, minHeight: 72)
                }
                .accessibilityLabel(preset.accessibilityLabel(widgetSets: session.widgetSets(preset)))
            }
        }
        .frame(width: width)
    }

    /// A tile for each theme, seven to a row, each with the top right of the screen in that theme with the chosen
    /// preset's widgets.
    private func themes(size: CGSize) -> some View {
        let choices = session.themes
        let width = (stageWidth(size) - 6 * 12) / 7
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(stride(from: 0, to: choices.count, by: 7)), id: \.self) { start in
                HStack(spacing: 12) {
                    ForEach(choices[start..<min(start + 7, choices.count)], id: \.key) { themeTile($0, size: size, width: width) }
                }
            }
        }
    }

    private func themeTile(_ choice: ThemeChoice, size: CGSize, width: Double) -> some View {
        let selected = choice.key == session.store.configurationStore.selectedThemeKey
        return SetupTile(selected: selected) { choose(choice) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    if let images = backdrop.images {
                        Image(decorative: images.sharp, scale: 1).resizable().frame(width: size.width, height: size.height)
                    }
                    if let preview = previews[choice.key] {
                        let look = preview.configuration(for: barAppearance)
                        ThemeSampleBar(look: look, widgets: session.preset.map { session.sampleWidgets($0, tokens: preview.tokens) })
                            .frame(width: size.width, height: 76)
                            .offset(y: -(76 - look.bar.height) / 2)
                    }
                }
                .environment(\.colorScheme, barAppearance.colorScheme)
                .scaleEffect(0.7, anchor: .topTrailing)
                .frame(width: width - 12, height: 54, alignment: .topTrailing)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .padding(6)
                HStack(spacing: 6) {
                    Text(choice.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if choice.key == session.currentThemeKey && !selected {
                        Text("Current").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).opacity(selected ? 1 : 0)
                }
                .padding(EdgeInsets(top: 2, leading: 11, bottom: 10, trailing: 11))
            }
            .frame(width: width)
        }
        .accessibilityLabel("\(choice.title) theme")
    }

    private func choose(_ choice: ThemeChoice) {
        session.preferences.theme = choice.key == session.currentThemeKey ? .current
            : .package(id: choice.manifest.id, version: choice.isBundled ? nil : choice.manifest.version)
    }

    /// Allow what your bar needs: one row for each thing macOS must allow, each with its own button, then the preset's
    /// Store widgets, each with its review.
    @ViewBuilder private func allow(size: CGSize, bar: CGRect) -> some View {
        let layout = allowLayout(size, bar: bar.height)
        title("Allow what your bar needs.", size: 36)
            .padding(.top, layout.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(motion.stepTransition(delay: 0))
        allowCard
            .frame(width: min(760, size.width - 80))
            .onGeometryChange(for: Double.self) { $0.size.height } action: { allowCardHeight = $0 }
            .padding(.top, layout.card)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(motion.stepTransition(delay: 0.06))
    }

    private var allowCard: some View {
        let calendars = session.needsCalendarAccess || session.preferences.widgetSets.contains(.meetings)
        let toAdd = session.storeWidgetsToAdd
        let widgets = session.preferences.widgetSets.compactMap { set -> (entry: PackageIndex.Entry, settings: [String: String])? in
            guard case let .store(id, _, _, settings) = set, let entry = session.storeEntries?.first(where: { $0.id == id }) else { return nil }
            return (entry, settings)
        }
        let leftOut = session.preset.map(session.leftOut) ?? []
        return VStack(alignment: .leading, spacing: 0) {
            section("macOS asks once for each").padding(EdgeInsets(top: 14, leading: 18, bottom: 2, trailing: 18))
            automationRow
            divider
            accessibilityRow
            if calendars {
                divider
                calendarRow
            }
            if session.showsSpacesGuidance {
                divider
                shortcutsRow
            }
            if let preset = session.preset, !widgets.isEmpty || !leftOut.isEmpty {
                section("Store widgets in \(preset.title)").padding(EdgeInsets(top: 16, leading: 18, bottom: 2, trailing: 18))
                ForEach(widgets, id: \.entry.key) { widget in
                    if widget.entry.id != widgets.first?.entry.id { divider }
                    let added = !toAdd.contains { $0.entry.id == widget.entry.id }
                    row(widget.entry.symbol ?? "shippingbox", widget.entry.name,
                        widget.entry.description ?? "Runs commands from the Store. Add shows you what before it's on your bar.", done: added) {
                        if added {
                            allowedLabel("Added")
                        } else if session.downloading == widget.entry.key && session.review == nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { Task { await session.review(widget) } } label: { Label("Add", systemImage: "plus") }
                                .buttonStyle(GlassButtonStyle(selected: true, size: .compact))
                                .accessibilityLabel("Add \(widget.entry.name)")
                        }
                    }
                }
                if !leftOut.isEmpty {
                    Text("The Store can't be reached, so \(preset.title) leaves out \(ListFormatter.localizedString(byJoining: leftOut)).")
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.62))
                        .padding(EdgeInsets(top: 8, leading: 18, bottom: 4, trailing: 18))
                }
            }
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(EdgeInsets(top: 8, leading: 18, bottom: 4, trailing: 18))
            }
        }
        .padding(.bottom, 8)
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 18))
        .glass(RoundedRectangle(cornerRadius: 18))
        .task {
            session.store.workspaceStore.refreshDesktopShortcuts()
            // A menu bar that already hides needs no Automation, so the bar can take its place at once.
            if session.menuBarHides && session.placementChoice == nil { await session.place(.top) }
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5).padding(.leading, 72)
    }

    private func row<Status: View>(_ symbol: String, _ title: String, _ detail: String, mac: String? = nil, done: Bool,
                                   @ViewBuilder status: () -> Status) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(done ? Self.allowed : .white)
                .frame(width: 40, height: 40)
                .background(done ? Color(red: 0.204, green: 0.78, blue: 0.349).opacity(0.22) : .white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if let mac { Text(mac).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.42)) }
                }
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            status()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .animation(motion.movement(.snappy(duration: 0.3)), value: done)
    }

    private func allowedLabel(_ text: String) -> some View {
        Label(text, systemImage: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Self.allowed)
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.62))
    }

    /// Automation lets StableBar hide the macOS menu bar. Refused, the bar sits below it instead.
    private var automationRow: some View {
        let phase = session.placementPhase
        let refused = if case .awaitingAccess = phase { true } else { false }
        let placed = if case .placed = phase { true } else { false }
        return row("menubar.rectangle", "Take the menu bar's place",
                   refused ? "StableBar sits below the menu bar, since macOS didn't allow Automation. Change it later in Settings."
                       : "Hides the macOS menu bar. It comes back when you point at the top edge.",
                   mac: "Automation", done: placed) {
            switch phase {
            case .placed:
                allowedLabel("Allowed")
            case .checkingAccess, .changingMenuBar:
                waiting("macOS is asking…")
            case .awaitingAccess:
                Button("Open Settings…") {
                    lower()
                    MenuBarAutoHide.openAutomationSettings()
                }
                .buttonStyle(GlassButtonStyle(selected: false, highlighted: true, size: .compact))
                .accessibilityLabel("Open Automation Settings")
            case .unchosen, .failed, .skipped:
                Button(SetupPermission.Action.allow.title) { Task { await session.place(.top) } }
                    .buttonStyle(GlassButtonStyle(selected: true, size: .compact))
                    .accessibilityLabel("Allow Automation")
            }
        }
    }

    private var accessibilityRow: some View {
        let name = session.system.macOSVersion.accessibilityName
        return row("cursorarrow.click.2", "Open menus from the bar",
                   "The Apple menu, your app's menus and menu bar items open from the bar, and windows keep clear of it.",
                   mac: name, done: session.accessibilityAccess) {
            if session.accessibilityAccess {
                allowedLabel("Allowed")
            } else {
                permissionButton(.allow, for: .accessibility) {
                    lower()
                    session.store.windowClearance.requestAccess()
                }
            }
        }
    }

    /// Calendars for Meetings, which can wait: Later saves Meetings turned off.
    private var calendarRow: some View {
        let allowed = session.calendarAccess == .fullAccess
        return row("calendar", "See your next meeting", "Meetings shows a countdown and Join before each call.",
                   mac: SetupPermission.calendars.title(on: session.system.macOSVersion), done: allowed) {
            if allowed {
                allowedLabel("Allowed")
            } else if session.preferences.deferMeetings {
                HStack(spacing: 8) {
                    Text("Later").font(.system(size: 13)).foregroundStyle(.white.opacity(0.62))
                    linkButton("Undo") { session.preferences.deferMeetings = false }
                }
            } else {
                HStack(spacing: 10) {
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
    }

    /// The Switch to Desktop shortcuts Workspaces uses on macOS Spaces. Setup finishes without them.
    private var shortcutsRow: some View {
        let status = session.store.workspaceStore.desktopShortcutStatus
        return row("keyboard", "Switch desktops from the bar",
                   "Turn on Switch to Desktop for each desktop in Keyboard Shortcuts → Mission Control.",
                   mac: "Optional", done: status.allEnabled) {
            if status.allEnabled {
                allowedLabel("Ready")
            } else {
                Button(DesktopShortcuts.actionTitle) {
                    lower()
                    do { try DesktopShortcuts.openSettings() }
                    catch { session.error = errorMessage(error) }
                }
                .buttonStyle(GlassButtonStyle(selected: false, highlighted: true, size: .compact))
            }
        }
        .help(status.detail)
        .accessibilityHint(status.detail)
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
            .background(.black.opacity(0.3), in: Capsule())
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
                             onEnable: { session.add($0, settings: $1) }, onAdded: { session.endReview() },
                             onWorkingChanged: { reviewIsWorking = $0 })
                    .id(review.inspection.manifest.versionKey)
                Button("Back") { session.endReview() }
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

    /// Continue, or Back and Finish setup, which waits for what the bar needs from macOS.
    private var toolbar: some View {
        let allowing = session.step == .allow
        return HStack(spacing: 2) {
            if allowing {
                Button {
                    withAnimation(motion.stageAnimation) { session.step = .choose }
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)).frame(width: 36)
                }
                .buttonStyle(GlassButtonStyle(selected: false, round: true))
                .accessibilityLabel("Back")
            }
            Button {
                if allowing { land() } else { withAnimation(motion.stageAnimation) { session.step = .allow } }
            } label: {
                HStack(spacing: 7) {
                    Text(allowing ? "Finish setup" : "Continue")
                    Image(systemName: allowing ? "checkmark" : "arrow.right")
                }
            }
            .buttonStyle(GlassButtonStyle(selected: true))
            .keyboardShortcut(.defaultAction)
            .disabled(allowing && !(session.readyToLand && session.missingPermissions.isEmpty))
        }
        .padding(4)
        .background(.black.opacity(0.3), in: Capsule())
        .glass(Capsule(style: .circular))
        .fixedSize()
    }

    /// The bar flies from the stage to its place as the backdrop fades, where the bar itself takes over from its copy;
    /// then a warm line spreads under it and the last card drops in.
    private func land() {
        raise()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.35) : .smooth(duration: 0.9)) { session.step = .done }
        Task {
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.35 : 0.9))
            reveal()
            withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .spring(duration: 0.7, bounce: 0.22)) { landed = true }
        }
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
