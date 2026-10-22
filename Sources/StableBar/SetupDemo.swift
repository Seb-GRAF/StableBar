import SwiftUI

/// The bar that setup's intro builds from widgets, clicks through, dresses in themes and flies to the real bar.
struct SetupDemo: View {
    let looks: [(name: String, look: Configuration)]
    /// Seconds since Get Started.
    let elapsed: Double
    let size: CGSize
    /// Where the bar is built, and the real bar it flies to.
    let stage: CGRect
    let target: CGRect

    /// When the bar leaves the stage, and when it reaches the real bar.
    static let flight = 11.2
    static let landing = 12.0

    private static let headlines = [("Built from widgets.", 0.9, 3.5), ("Click any of them.", 3.8, 7.3),
                                    ("Dress it in any theme.", 7.7, 10.85)]
    /// The parts in bar order, with when each lands.
    private static let parts = [("workspaces", 1.1), ("active app", 1.24), ("now playing", 1.8),
                                ("cpu", 1.66), ("battery", 1.52), ("clock", 1.38)]
    private static let events = [("09:30", "Standup"), ("13:00", "Design review"), ("16:30", "Ship it")]
    private static let clockClick = 4.45
    private static let cpuClick = 6.25
    private static let wipes = 7.9
    private static let finder = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
    private static let safari = NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")

    var body: some View {
        let flight = UnitCurve.easeInOut.value(at: progress(elapsed, Self.flight, Self.landing - Self.flight))
        let theme = theme(at: elapsed)
        let filled = progress(elapsed, 0.95, 0.35)
        ZStack {
            ZStack {
                glow(theme.from).opacity(1 - theme.wipe)
                glow(theme.to).opacity(theme.wipe)
            }
            .opacity(0.35 * filled * (1 - flight))
            .position(x: stage.midX, y: stage.midY)
            guides.opacity(1 - progress(elapsed, 3.3, 0.5))
            ZStack {
                if theme.wipe < 1 {
                    bar(theme.from).mask { wipe(1 - theme.wipe, from: .trailing) }
                }
                bar(theme.to).mask { wipe(theme.wipe, from: .leading) }
            }
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, .white, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(width: 2, height: proxy.size.height + 40)
                        .shadow(color: accent(looks[theme.to].look), radius: 10)
                        .position(x: proxy.size.width * theme.wipe, y: proxy.size.height / 2)
                        .opacity(theme.wipe > 0 && theme.wipe < 1 ? 1 : 0)
                }
            }
            .frame(width: stage.width + (target.width - stage.width) * flight)
            .position(x: stage.midX, y: stage.midY + (target.midY - stage.midY) * flight)
            .opacity(1 - progress(elapsed, Self.landing, 0.25))
            ZStack {
                if elapsed >= Self.wipes {
                    Text(looks[theme.to].name).id(theme.to).transition(.blurFade)
                }
            }
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
            .animation(.smooth(duration: 0.4), value: theme.to)
            .opacity(1 - progress(elapsed, 10.85, 0.35))
            .position(x: stage.midX, y: stage.maxY + 48)
            ForEach(Self.headlines.indices, id: \.self) { index in
                let (text, start, end) = Self.headlines[index]
                if elapsed >= start && elapsed < end + 0.35 {
                    headline(text, start: start, end: end)
                        .position(x: stage.midX, y: stage.minY - 96)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .overlayPreferenceValue(SetupDemoParts.self) { parts in
            GeometryReader { proxy in
                if let clock = parts[5].map({ proxy[$0] }), let cpu = parts[3].map({ proxy[$0] }) {
                    popup(clock: clock, cpu: cpu)
                    cursor(clock: clock, cpu: cpu)
                }
            }
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }

    /// The look being wiped away, the look replacing it, and how far the wipe has come.
    private func theme(at time: Double) -> (from: Int, to: Int, wipe: Double) {
        let order = [0] + looks.indices.dropFirst() + [0]
        let step = min(max(Int(((time - Self.wipes) / 0.9).rounded(.down)) + 1, 0), order.count - 1)
        guard step > 0 else { return (0, 0, 1) }
        return (order[step - 1], order[step], progress(time, Self.wipes + 0.9 * Double(step - 1), 0.5))
    }

    private func accent(_ look: Configuration) -> Color {
        WidgetAppearance(look.defaults.resolved(for: StyleStates()), defaults: WidgetStyle()).accent
    }

    private func glow(_ index: Int) -> some View {
        Ellipse()
            .fill(accent(looks[index].look))
            .frame(width: stage.width * 0.8, height: 140)
            .blur(radius: 70)
    }

    private func wipe(_ fraction: Double, from edge: Alignment) -> some View {
        GeometryReader { proxy in
            Rectangle()
                .frame(width: proxy.size.width * fraction, height: proxy.size.height + 120)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge)
        }
    }

    private var guides: some View {
        let grow = UnitCurve.easeOut.value(at: progress(elapsed, 0.3, 0.8))
        return ZStack {
            Path { path in
                for y in [stage.minY - 0.5, stage.maxY + 0.5] {
                    path.move(to: CGPoint(x: stage.midX - size.width / 2 * grow, y: y))
                    path.addLine(to: CGPoint(x: stage.midX + size.width / 2 * grow, y: y))
                }
            }
            .stroke(Color.orange.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
            Group {
                Path { path in
                    for x in [stage.minX, stage.maxX] {
                        path.move(to: CGPoint(x: x, y: stage.minY - 30))
                        path.addLine(to: CGPoint(x: x, y: stage.maxY + 30))
                    }
                    for (from, to) in [(stage.minX, stage.midX - 64), (stage.midX + 64, stage.maxX)] {
                        path.move(to: CGPoint(x: from, y: stage.minY - 22))
                        path.addLine(to: CGPoint(x: to, y: stage.minY - 22))
                    }
                }
                .stroke(Color.orange.opacity(0.6), lineWidth: 1)
                Text("\(Int(stage.width)) × \(Int(stage.height)) pt")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.orange)
                    .position(x: stage.midX, y: stage.minY - 22)
            }
            .opacity(progress(elapsed, 0.6, 0.3))
        }
    }

    private func headline(_ text: String, start: Double, end: Double) -> some View {
        let words = text.split(separator: " ")
        let out = progress(elapsed, end, 0.35)
        return HStack(spacing: 9) {
            ForEach(words.indices, id: \.self) { index in
                let shown = UnitCurve.easeOut.value(at: progress(elapsed, start + Double(index) * 0.07, 0.45))
                Text(words[index])
                    .blur(radius: 8 * (1 - shown))
                    .opacity(shown)
                    .offset(y: 14 * (1 - shown))
            }
        }
        .font(.system(size: 34, weight: .semibold))
        .tracking(-0.5)
        .fixedSize()
        .opacity(1 - out)
        .blur(radius: 6 * out)
        .offset(y: -8 * out)
    }

    private func bar(_ index: Int) -> some View {
        let look = looks[index].look
        let sample = ThemeSampleBar(look: look)
        let filled = progress(elapsed, 0.95, 0.35)
        let focused = elapsed < 2.6 ? 1 : 2
        return HStack(spacing: look.bar.spacing) {
            part(0) { sample.workspaces(active: focused).animation(.smooth(duration: 0.3), value: focused) }
            part(1) { sample.tile(role: .primary) { app } }
            Spacer(minLength: 0)
            part(3) { sample.tile(role: .value) { cpu(accent: accent(look)) } }
            part(4) {
                sample.tile(role: .value) {
                    HStack(spacing: 4) {
                        Image(systemName: "battery.75percent")
                        Text("82%")
                    }
                }
            }
            part(5) { sample.tile(role: .time) { clock } }
        }
        .overlay {
            part(2) {
                sample.tile(role: .primary) {
                    HStack(spacing: 7) {
                        Equalizer(playing: true, height: 11)
                        Text("Midnight City · M83")
                    }
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, look.bar.inset)
        .frame(height: sample.stripHeight)
        .background {
            RoundedRectangle(cornerRadius: sample.barStyle.cornerRadius ?? 0)
                .fill((sample.barStyle.background ?? look.bar.background).shapeStyle)
                .opacity(filled)
        }
        .overlay { BarBorder(style: sample.barStyle).opacity(filled) }
        .padding(look.bar.margin)
    }

    /// A part of the bar that drops into its slot, sparks, and is labelled while the bar is built.
    private func part<Content: View>(_ index: Int, @ViewBuilder content: () -> Content) -> some View {
        let (name, drop) = Self.parts[index]
        let shown = progress(elapsed, drop, 0.2)
        let settled = Spring(duration: 0.55, bounce: 0.35).value(target: 1.0, time: max(elapsed - drop, 0))
        let spark = progress(elapsed, drop + 0.1, 0.5)
        let click = index == 5 ? Self.clockClick : index == 3 ? Self.cpuClick : -1
        return content()
            .blur(radius: 8 * (1 - shown))
            .opacity(shown)
            .rotation3DEffect(.degrees(80 * (1 - settled)), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.4)
            .offset(y: -30 * (1 - settled))
            .scaleEffect(1 - 0.06 * sin(.pi * progress(elapsed, click, 0.18)))
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .opacity(progress(elapsed, 0.6, 0.3) * (1 - shown))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.orange, lineWidth: 1.5)
                    .padding(-10 * spark)
                    .opacity(spark > 0 ? 0.9 * (1 - spark) : 0)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 4) {
                    Rectangle().frame(width: 1, height: 12)
                    Text(name).font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(Color.orange.opacity(0.85))
                .fixedSize()
                .alignmentGuide(.bottom) { $0[.top] - 6 }
                .opacity(progress(elapsed, drop + 0.2, 0.3) * (1 - progress(elapsed, 3.3, 0.4)))
            }
            .anchorPreference(key: SetupDemoParts.self, value: .bounds) { [index: $0] }
    }

    private var app: some View {
        let safari = elapsed >= 2.6
        return ZStack {
            HStack(spacing: 6) {
                Image(nsImage: safari ? Self.safari : Self.finder).resizable().frame(width: 16, height: 16)
                Text(safari ? "Safari" : "Finder")
            }
            .id(safari)
            .transition(.blurFade)
        }
        .animation(.smooth(duration: 0.35), value: safari)
    }

    private func cpu(accent: Color) -> some View {
        let percent = [12, 18, 15, 23, 9, 14][Int(elapsed * 1.5) % 6]
        return HStack(spacing: 6) {
            Image(systemName: "cpu")
            Sparkline(samples: samples).stroke(accent, lineWidth: 1.2).frame(width: 34, height: 12)
            Text("\(percent)%")
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth, value: percent)
        }
    }

    private var clock: some View {
        let minute = elapsed < 3 ? 41 : 42
        return HStack(spacing: 8) {
            Text(Date.now, format: .dateTime.weekday().day().month())
            Text("9:\(minute)")
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth, value: minute)
        }
    }

    private var samples: [Double] {
        (0..<60).map { index in
            let x = Double(index) / 4 + elapsed * 3
            return 0.45 + 0.25 * sin(x) + 0.15 * sin(x * 2.7)
        }
    }

    @ViewBuilder
    private func popup(clock: CGRect, cpu: CGRect) -> some View {
        let open = Spring(duration: 0.45, bounce: 0.3).value(target: 1.0, time: max(elapsed - Self.clockClick - 0.05, 0))
        let move = Spring(duration: 0.5, bounce: 0.2).value(target: 1.0, time: max(elapsed - Self.cpuClick - 0.05, 0))
        let close = progress(elapsed, 7.2, 0.25)
        if elapsed > Self.clockClick && close < 1 {
            card(system: elapsed > Self.cpuClick)
                .scaleEffect(x: 0.9 + 0.1 * open, y: 0.5 + 0.5 * open, anchor: .top)
                .blur(radius: 6 * max(1 - open, 0) + 4 * close)
                .opacity(min(open * 2, 1) * (1 - close))
                .offset(x: clock.midX + (cpu.midX - clock.midX) * move - 125, y: clock.maxY + 16)
        }
    }

    private func card(system: Bool) -> some View {
        let look = looks[0].look
        let appearance = WidgetAppearance(look.popupDefaults.inheriting(look.defaults).resolved(for: StyleStates()),
                                          defaults: WidgetStyle())
        return ZStack(alignment: .topLeading) {
            if system {
                VStack(alignment: .leading, spacing: 9) {
                    Text("System").font(.system(size: 13, weight: .semibold))
                    Sparkline(samples: samples).stroke(appearance.accent, lineWidth: 1.5).frame(height: 34)
                    meter("CPU", 0.18, appearance)
                    meter("Memory", 0.54, appearance)
                }
                .transition(.blurFade)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Today").font(.system(size: 13, weight: .semibold))
                    ForEach(Self.events, id: \.0) { event in
                        HStack(spacing: 9) {
                            Capsule().fill(appearance.accent).frame(width: 3, height: 15)
                            Text(event.0).monospacedDigit().opacity(0.55)
                            Text(event.1)
                        }
                    }
                }
                .transition(.blurFade)
            }
        }
        .font(appearance.font)
        .foregroundStyle(appearance.foreground)
        .padding(14)
        .frame(width: 250, alignment: .topLeading)
        .background(appearance.background, in: RoundedRectangle(cornerRadius: appearance.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: appearance.cornerRadius).strokeBorder(appearance.borderColor, lineWidth: appearance.borderWidth))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .animation(.smooth(duration: 0.4), value: system)
    }

    private func meter(_ title: String, _ value: Double, _ appearance: WidgetAppearance) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).opacity(0.55)
                Spacer()
                Text("\(Int(value * 100))%").monospacedDigit()
            }
            Capsule()
                .fill(appearance.foreground.opacity(0.15))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(appearance.accent).frame(width: proxy.size.width * value)
                    }
                }
        }
    }

    @ViewBuilder
    private func cursor(clock: CGRect, cpu: CGRect) -> some View {
        let start = CGPoint(x: clock.midX + 150, y: clock.maxY + 170)
        let exit = CGPoint(x: cpu.midX + 110, y: cpu.maxY + 210)
        let toClock = UnitCurve.easeInOut.value(at: progress(elapsed, 3.8, 0.6))
        let toCPU = UnitCurve.easeInOut.value(at: progress(elapsed, 5.7, 0.5))
        let away = UnitCurve.easeInOut.value(at: progress(elapsed, 6.95, 0.6))
        let x = start.x + (clock.midX - start.x) * toClock + (cpu.midX - clock.midX) * toCPU + (exit.x - cpu.midX) * away
        let y = start.y + (clock.midY - start.y) * toClock + (cpu.midY - clock.midY) * toCPU + (exit.y - cpu.midY) * away
            - 28 * sin(.pi * toCPU)
        let shown = progress(elapsed, 3.6, 0.25) * (1 - progress(elapsed, 7.25, 0.3))
        if shown > 0 {
            ForEach([(Self.clockClick, clock), (Self.cpuClick, cpu)], id: \.0) { click in
                let ripple = progress(elapsed, click.0, 0.5)
                Circle()
                    .strokeBorder(.white, lineWidth: 1.5)
                    .frame(width: 8 + 40 * ripple, height: 8 + 40 * ripple)
                    .opacity(ripple > 0 && ripple < 1 ? 1 - ripple : 0)
                    .position(x: click.1.midX, y: click.1.midY)
            }
            let arrow = NSCursor.arrow
            let press = max(sin(.pi * progress(elapsed, Self.clockClick, 0.18)), sin(.pi * progress(elapsed, Self.cpuClick, 0.18)))
            Image(nsImage: arrow.image)
                .scaleEffect(1 - 0.18 * press, anchor: .topLeading)
                .position(x: x + arrow.image.size.width / 2 - arrow.hotSpot.x, y: y + arrow.image.size.height / 2 - arrow.hotSpot.y)
                .opacity(shown)
        }
    }
}

private struct SetupDemoParts: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]

    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
