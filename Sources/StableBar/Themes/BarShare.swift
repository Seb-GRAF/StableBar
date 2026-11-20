import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

@MainActor let barShare = BarShareWindow()

@MainActor
final class BarShareWindow: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private weak var store: BarStore?

    /// Opens Share My Bar on `screen`'s bar, or shows that bar in it when it's already open.
    func show(store: BarStore, screen: NSScreen) {
        self.store = store
        store.barEditing.end()
        let share = BarShare(store: store, display: BarDisplay(screen: screen), screen: screen.frame.size, menuBar: screen.menuBarHeight,
                             wallpaper: NSWorkspace.shared.desktopImageURL(for: screen).flatMap(NSImage.init(contentsOf:)),
                             defaults: .standard)
        let host = NSHostingView(rootView: BarShareView(share: share) { [weak self] in self?.window?.performClose(nil) })
        if window == nil {
            // A title bar with nothing in it keeps the panel resizable and closable with ⌘W, behind a borderless look.
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
                                 styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                                 backing: .buffered, defer: false)
            window.title = "Share My Bar"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            window.minSize = NSSize(width: 520, height: 360)
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window!.contentView = host
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window!.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // Settings keeps StableBar in the Dock while it's open.
        if store?.widgetScripts.inspectorOpen != true { NSApplication.shared.setActivationPolicy(.accessory) }
    }
}

/// The screen Share My Bar draws the bar on: the one it opened on, or a MacBook's at its default size.
enum BarShareScreen: String, CaseIterable, Identifiable, Decodable {
    case this, air13, pro14, pro16

    var id: Self { self }

    var title: String {
        switch self {
        case .this: "This screen"
        case .air13: "13″ MacBook Air"
        case .pro14: "14″ MacBook Pro"
        case .pro16: "16″ MacBook Pro"
        }
    }

    /// The MacBook's screen, its notch's width and its menu bar's height with the notch, in points.
    var macBook: (size: CGSize, notch: CGFloat, menuBar: Double)? {
        switch self {
        case .this: nil
        case .air13: (CGSize(width: 1470, height: 956), 186, 33)
        case .pro14: (CGSize(width: 1512, height: 982), 211, 37)
        case .pro16: (CGSize(width: 1728, height: 1117), 211, 37)
        }
    }
}

enum BarSharePreset: String, CaseIterable, Identifiable, Decodable {
    case bar, landscape, square, portrait

    var id: Self { self }

    /// The name in the toolbar.
    var label: String {
        switch self {
        case .bar: "Bar"
        case .landscape: "16:9"
        case .square: "1:1"
        case .portrait: "4:5"
        }
    }

    /// The name VoiceOver reads.
    var title: String {
        switch self {
        case .bar: "Bar only"
        case .landscape: "16:9"
        case .square: "Square"
        case .portrait: "4:5"
        }
    }

    /// Twice the usual sizes for social media, so the bar's small text stays sharp. The bar alone is twice the
    /// screen's width.
    var pixels: NSSize? {
        switch self {
        case .bar: nil
        case .landscape: NSSize(width: 3200, height: 1800)
        case .square: NSSize(width: 2160, height: 2160)
        case .portrait: NSSize(width: 2160, height: 2700)
        }
    }
}

/// What Share My Bar draws: the screen, with or without the MacBook's notch, and the image's shape.
struct BarShareFormat: Equatable {
    var screen = BarShareScreen.this
    var notch = true
    var preset = BarSharePreset.bar
}

/// The bar of one screen as it is now, at its place on the desktop over the screen's wallpaper, drawn as an image of
/// the chosen format, with StableBar's badge in a corner unless it's turned off.
@MainActor @Observable
final class BarShare {
    static let badgeKey = "shareMyBarBadge"

    /// The desktop as drawn, without the badge, `size` points large; `bottom` for a bar at the bottom.
    struct Drawing {
        let image: CGImage
        let size: CGSize
        let bottom: Bool
    }

    var format = BarShareFormat()
    /// Whether the image carries StableBar's logo and website, remembered for the next share.
    var badge: Bool {
        didSet {
            defaults?.set(badge, forKey: Self.badgeKey)
            compose()
        }
    }
    private(set) var drawn: Drawing?
    /// `drawn`'s image with the badge when it's on.
    private(set) var image: CGImage?
    /// Where the badge goes in the image, in points from its top left, whether it's on or not.
    private(set) var badgeFrame: CGRect?
    /// The image blurred, behind the window. Blurred here rather than by SwiftUI, whose blur offscreen drawings leave out.
    private(set) var backdrop: NSImage?
    @ObservationIgnored private let store: BarStore
    @ObservationIgnored private let display: BarDisplay
    @ObservationIgnored private let screen: CGSize
    @ObservationIgnored private let menuBar: Double
    /// Nil when the wallpaper has no still image, as a dynamic or aerial one can.
    @ObservationIgnored private let wallpaper: NSImage?
    /// Nil where the badge's choice isn't kept, as in scenes.
    @ObservationIgnored private let defaults: UserDefaults?
    /// Whether `format`'s screen has a notch, which the image can leave out.
    var hasNotch: Bool { format.screen.macBook != nil || display.notch != nil }
    /// The bar link and what it carries, or why the bar can't be shared as one.
    private(set) var link: Result<BarLink.Sharing, Error>?

    init(store: BarStore, display: BarDisplay, screen: CGSize, menuBar: Double, wallpaper: NSImage?, defaults: UserDefaults? = nil) {
        self.store = store
        self.display = display
        self.screen = screen
        self.menuBar = menuBar
        self.wallpaper = wallpaper
        self.defaults = defaults
        badge = defaults?.object(forKey: Self.badgeKey) as? Bool ?? true
    }

    /// `image` as PNG, at twice its size in points per inch, as Copy, Save and Share give it.
    var png: Data? {
        guard let image, let drawn else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = drawn.size
        return rep.representation(using: .png, properties: [:])
    }

    /// Draws the top of the desktop, or its bottom for a bar at the bottom, at the width of `format`'s screen and in
    /// its shape. A MacBook's screen shows the bar as it lays out there, around the notch when it has one. The bar
    /// alone gets 120 points of wallpaper beyond it. The wallpaper fills the screen, or the image when that's taller.
    /// Clocks show `fixedDate`, or the time now, and a bar without its own appearance takes `colorScheme`.
    func draw(fixedDate: Date?, colorScheme: ColorScheme) async {
        image = nil
        var display = display
        var screen = screen
        var menuBar = menuBar
        if let macBook = format.screen.macBook {
            display = BarDisplay(id: display.id, isBuiltIn: true, isMain: display.isMain,
                                 notch: (macBook.size.width - macBook.notch) / 2...(macBook.size.width + macBook.notch) / 2)
            display.notchHeight = macBook.menuBar
            screen = macBook.size
            menuBar = format.notch ? macBook.menuBar : 24
        }
        if !format.notch {
            display = BarDisplay(id: display.id, isBuiltIn: display.isBuiltIn, isMain: display.isMain, notch: nil, isPortrait: display.isPortrait)
        }
        let configuration = store.configuration?.onScreen(ScreenKind(display))
        let bottom = configuration?.bar.position == .bottom
        let edge = (bottom ? configuration?.bar.offset : configuration?.bar.top(menuBar: menuBar)) ?? 0
        let strip = edge + (configuration?.barGeometry(for: display).panelHeight ?? 0) + 120
        let pixels = format.preset.pixels ?? NSSize(width: screen.width * 2, height: strip * 2)
        let size = NSSize(width: screen.width, height: screen.width * pixels.height / pixels.width)
        let dark = (configuration?.bar.appearance?.colorScheme ?? colorScheme) == .dark
        let desktop = BarView(store: store, display: display, preview: true)
            .padding(bottom ? .bottom : .top, edge)
            .frame(width: size.width, height: max(screen.height, size.height))
            .overlay(alignment: .top) {
                if let notch = display.notch {
                    UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11)
                        .fill(.black)
                        .frame(width: notch.upperBound - notch.lowerBound, height: display.notchHeight)
                }
            }
            .background {
                if let wallpaper {
                    Image(nsImage: wallpaper).resizable().scaledToFill()
                } else {
                    OffscreenSnapshot.backdrop(dark: dark)
                }
            }
            .frame(width: size.width, height: size.height, alignment: bottom ? .bottom : .top)
            .clipped()
            .environment(\.fixedDate, fixedDate)
        let png = try? await OffscreenSnapshot.png(desktop, size: size, pixels: pixels, dark: dark, settle: .after(.seconds(1)),
                                                   name: "Share My Bar")
        guard !Task.isCancelled else { return }
        drawn = png.flatMap { NSBitmapImageRep(data: $0)?.cgImage }.map { Drawing(image: $0, size: size, bottom: bottom) }
        backdrop = drawn.flatMap { Self.blurred($0.image) }
        compose()
        // Made right after the drawing, on the main actor, so the link carries the bar the image shows.
        link = Result { try BarLink.sharing(store, on: display) }
    }

    private func compose() {
        guard let drawn else {
            image = nil
            badgeFrame = nil
            return
        }
        let scale = CGFloat(drawn.image.width) / drawn.size.width
        let art = BarShareBadge.render(scale: scale)
        badgeFrame = art.map {
            Self.badgeFrame(CGSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale), in: drawn.size, bottom: drawn.bottom)
        }
        if badge, let art, let badgeFrame {
            image = Self.composite(drawn.image, badge: art, at: badgeFrame, scale: scale) ?? drawn.image
        } else {
            image = drawn.image
        }
    }

    /// The frame of a badge `badge` large in an image `size` large: in its bottom-right corner, or its top-right one
    /// for a bar at the bottom, so it sits on the wallpaper beyond the bar.
    nonisolated static func badgeFrame(_ badge: CGSize, in size: CGSize, bottom: Bool) -> CGRect {
        CGRect(x: size.width - badge.width - BarShareBadge.inset,
               y: bottom ? BarShareBadge.inset : size.height - badge.height - BarShareBadge.inset,
               width: badge.width, height: badge.height)
    }

    /// `image` with `badge` over it at `frame`, in points from its top left, `scale` pixels to a point.
    nonisolated static func composite(_ image: CGImage, badge: CGImage, at frame: CGRect, scale: CGFloat) -> CGImage? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: bounds)
        // Core Graphics counts from the bottom left.
        context.draw(badge, in: CGRect(x: frame.minX * scale, y: bounds.height - frame.maxY * scale,
                                       width: frame.width * scale, height: frame.height * scale))
        return context.makeImage()
    }

    /// Blurred at a quarter of the size, which looks the same behind the window for a sixteenth of the work.
    private static func blurred(_ image: CGImage) -> NSImage? {
        let small = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 10).cropped(to: small.extent)
        return CIContext().createCGImage(blurred, from: small.extent).map { NSImage(cgImage: $0, size: small.extent.size) }
    }
}

/// StableBar's logo, name and website, as Share My Bar draws them in a corner of the image.
struct BarShareBadge: View {
    /// From the image's edges to the badge, whose own `padding` leaves room for its shadow.
    nonisolated static let inset: CGFloat = 12
    nonisolated static let padding: CGFloat = 12
    private static let wordmark = Font(shantellSans("shantell-sans-display", size: 22))

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "StableBar").font(Self.wordmark)
                Text(verbatim: "stablebar.app").font(.system(size: 13, weight: .medium)).opacity(0.88)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 5, y: 1)
        .padding(Self.padding)
    }

    /// The badge, `scale` pixels to a point.
    static func render(scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: BarShareBadge())
        renderer.scale = scale
        return renderer.cgImage
    }
}

struct BarShareView: View {
    @Bindable var share: BarShare
    @State var showsLink = false
    @State var showsDetails = false
    var close: () -> Void = {}
    @State private var detailsHeight: CGFloat = 0
    @State private var copied = false
    @State private var overImage = false
    @Environment(\.fixedDate) private var fixedDate
    @Environment(\.colorScheme) private var colorScheme
    @State private var anchor = NSView()

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top) {
                screenMenu
                Spacer(minLength: 12)
                closeButton
            }
            stage
            toolbar
        }
        .padding(14)
        .overlay(alignment: .bottom) {
            if showsLink { linkCard.padding(.top, 56).padding(.bottom, 70) }
        }
        .background { backdrop.overlay(WindowDragArea()) }
        .ignoresSafeArea()
        // The window stays dark over any image, while `colorScheme` still gives a bar without its own appearance its look.
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .frame(minWidth: 520, minHeight: 360)
        .task(id: share.format) { await share.draw(fixedDate: fixedDate, colorScheme: colorScheme) }
        .onChange(of: showsLink) { copied = false }
        .onChange(of: share.format) { copied = false }
    }

    private var backdrop: some View {
        Color(white: 0.14)
            .overlay {
                if let backdrop = share.backdrop { Image(nsImage: backdrop).resizable().scaledToFill() }
            }
            .overlay(LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom))
            .clipped()
    }

    private var screenMenu: some View {
        Menu {
            Picker("Screen", selection: $share.format.screen) {
                ForEach(BarShareScreen.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            if share.hasNotch { Toggle("Notch", isOn: $share.format.notch) }
            Toggle("StableBar Badge", isOn: $share.badge)
        } label: {
            HStack(spacing: 6) {
                Text(share.format.screen.title)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.8)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .glass(Capsule(style: .circular))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var closeButton: some View {
        Button {
            if showsLink { showsLink = false } else { close() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .glass(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Close")
        .accessibilityLabel("Close")
    }

    /// The image over a blur of itself, with the badge's spot.
    private var stage: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = share.image, let drawn = share.drawn {
                    let fit = Self.fit(drawn.size, in: proxy.size)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                        .overlay(alignment: .topLeading) {
                            if let frame = share.badgeFrame { badgeSpot(frame, scale: fit.width / drawn.size.width) }
                        }
                        .onHover { overImage = $0 }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// The badge's corner while the pointer is over the image: the badge with a button that removes it, or a button
    /// that brings it back.
    @ViewBuilder private func badgeSpot(_ frame: CGRect, scale: CGFloat) -> some View {
        let shown = frame.insetBy(dx: BarShareBadge.padding, dy: BarShareBadge.padding)
        let rect = CGRect(x: shown.minX * scale, y: shown.minY * scale, width: shown.width * scale, height: shown.height * scale)
        if overImage {
            Group {
                if share.badge {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .padding(-4)
                        .overlay(alignment: .topLeading) {
                            Button { share.badge = false } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .heavy))
                                    .frame(width: 18, height: 18)
                                    .background(Color(white: 0.17), in: Circle())
                                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: -13, y: -13)
                            .help("Remove the StableBar badge")
                            .accessibilityLabel("Remove StableBar Badge")
                        }
                } else {
                    Button { share.badge = true } label: {
                        Label("Badge", systemImage: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(.black.opacity(0.45), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Add the StableBar badge")
                    .frame(width: rect.width, height: rect.height, alignment: .trailing)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            ForEach(BarSharePreset.allCases) { preset in
                Button(preset.label) { share.format.preset = preset }
                    .buttonStyle(ShareToolStyle(selected: share.format.preset == preset))
                    .accessibilityLabel(preset.title)
                    .accessibilityAddTraits(share.format.preset == preset ? .isSelected : [])
            }
            Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 20).padding(.horizontal, 6)
            tool("doc.on.doc", "Copy Image", action: copy).disabled(share.image == nil)
            tool("square.and.arrow.down", "Save Image…", action: save).disabled(share.image == nil)
            tool("link", "Bar Link", selected: showsLink) { showsLink.toggle() }.disabled(share.link == nil)
            Button(action: shareBar) {
                Label("Share", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
            }
            .buttonStyle(ShareToolStyle(selected: true))
            .keyboardShortcut(.defaultAction)
            .background(MenuAnchor(view: anchor))
            .disabled(share.image == nil)
            .padding(.leading, 4)
        }
        .padding(4)
        .glass(Capsule(style: .circular))
        .fixedSize()
    }

    private func tool(_ symbol: String, _ title: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 36)
        }
        .buttonStyle(ShareToolStyle(selected: false, highlighted: selected, round: true))
        .help(title)
        .accessibilityLabel(title)
    }

    /// The bar link, what it shares and what stays on this Mac, above the toolbar.
    @ViewBuilder private var linkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch share.link {
            case let .success(sharing)?:
                HStack {
                    Label("Bar link", systemImage: "link").font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 12)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sharing.link.absoluteString, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(ShareToolStyle(selected: true, compact: true))
                    // While the image redraws, the link is still the last screen's.
                    .disabled(share.image == nil)
                }
                Text("Anyone with StableBar can try your bar and keep the widgets they like. Scripts and private settings stay on your Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                details(sharing)
            case let .failure(error)?:
                Text(errorMessage(error)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).textSelection(.enabled)
            case nil: EmptyView()
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(Color(white: 0.13).opacity(0.97), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }

    private func details(_ sharing: BarLink.Sharing) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation { showsDetails.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.6)
                        .rotationEffect(.degrees(showsDetails ? 90 : 0))
                    Text("What it shares").font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsDetails {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        SharedRow(symbol: "paintpalette", name: "Look", detail: sharing.look)
                        ForEach(Array(sharing.widgets.filter { $0.leftOut == nil }.enumerated()), id: \.offset) { _, widget in
                            SharedRow(symbol: widget.symbol, name: widget.name, store: widget.store,
                                      detail: widget.settings.isEmpty ? nil : widget.settings.joined(separator: " · "))
                        }
                        let stays = sharing.widgets.filter { $0.leftOut != nil || !$0.settingsLeftOut.isEmpty }
                        if !stays.isEmpty {
                            Text("Stays on your Mac")
                                .font(.system(size: 11.5, weight: .semibold))
                                .opacity(0.6)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(Array(stays.enumerated()), id: \.offset) { _, widget in
                                SharedRow(symbol: widget.symbol, name: widget.name,
                                          detail: widget.leftOut ?? widget.settingsLeftOut.joined(separator: " · "), dimmed: true)
                            }
                        }
                    }
                    .padding(.top, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
                }
                .frame(maxHeight: detailsHeight)
            }
        }
    }

    /// `size` scaled to fit in `space`.
    static func fit(_ size: CGSize, in space: CGSize) -> CGSize {
        let scale = max(0, min(space.width / size.width, space.height / size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func copy() {
        guard let png = share.png else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    private func save() {
        guard let png = share.png else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "StableBar.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try png.write(to: url) } catch { NSAlert(error: error).runModal() }
    }

    private func shareBar() {
        guard let png = share.png else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "StableBar.png")
        do {
            try png.write(to: url)
            NSSharingServicePicker(items: [url]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Moves the window when dragged, wherever no control above it takes the click. A window's
/// `isMovableByWindowBackground` doesn't move it from SwiftUI content.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// A translucent fill and edge over the blurred image, for the window's controls. Their capsules are circular: a
/// continuous capsule's edge gets a stray straight line beside it in offscreen drawings.
private extension View {
    func glass(_ shape: some InsettableShape) -> some View {
        background(.white.opacity(0.15), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.24), lineWidth: 0.5))
    }
}

/// A button in the toolbar: a shape, a tool or Share, which is `selected` like the current shape.
private struct ShareToolStyle: ButtonStyle {
    var selected: Bool
    var highlighted = false
    var round = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12, weight: .semibold))
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.horizontal, round ? 0 : compact ? 10 : 12)
            .frame(minWidth: compact ? 0 : 36, minHeight: compact ? 26 : 36)
            .background(fill(pressed: configuration.isPressed), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }

    private func fill(pressed: Bool) -> Color {
        if selected { return .white.opacity(pressed ? 0.75 : 0.92) }
        return .white.opacity(pressed ? 0.28 : highlighted ? 0.22 : 0)
    }
}

/// A row of "What it shares": the look, a widget the link carries, or what stays on this Mac.
private struct SharedRow: View {
    let symbol: String
    let name: String
    var store = false
    var detail: String?
    var dimmed = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name).lineLimit(1)
                    if store { PackageOriginBadge(source: .store) }
                }
                if let detail { Text(detail).font(.system(size: 11)).opacity(0.6).lineLimit(1) }
            }
        }
        .opacity(dimmed ? 0.6 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Color.white.opacity(0.08).frame(height: 1) }
    }
}
