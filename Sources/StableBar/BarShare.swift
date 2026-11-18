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
                             wallpaper: NSWorkspace.shared.desktopImageURL(for: screen).flatMap(NSImage.init(contentsOf:)))
        let host = NSHostingView(rootView: BarShareView(share: share))
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Share My Bar"
            window.minSize = NSSize(width: 560, height: 480)
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
        if store?.inspectorOpen != true { NSApplication.shared.setActivationPolicy(.accessory) }
    }
}

enum BarSharePreset: String, CaseIterable, Identifiable {
    case bar = "Bar only", landscape = "Landscape 16:9", square = "Square 1:1", portrait = "Portrait 4:5"

    var id: Self { self }

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

/// The bar of one screen as it is now, at its place on the desktop over the screen's wallpaper, drawn as an image of
/// the chosen preset.
@MainActor @Observable
final class BarShare {
    var preset = BarSharePreset.bar
    /// The image of `preset`, once drawn.
    private(set) var png: Data?
    /// `png` blurred, behind the preview. Blurred here rather than by SwiftUI, whose blur offscreen drawings leave out.
    var backdrop: NSImage? {
        png.flatMap(CIImage.init(data:)).map { image in
            let rep = NSCIImageRep(ciImage: image.clampedToExtent().applyingGaussianBlur(sigma: 40).cropped(to: image.extent))
            let backdrop = NSImage(size: rep.size)
            backdrop.addRepresentation(rep)
            return backdrop
        }
    }
    @ObservationIgnored private let store: BarStore
    @ObservationIgnored private let display: BarDisplay
    @ObservationIgnored private let screen: CGSize
    @ObservationIgnored private let menuBar: Double
    /// Nil when the wallpaper has no still image, as a dynamic or aerial one can.
    @ObservationIgnored private let wallpaper: NSImage?

    init(store: BarStore, display: BarDisplay, screen: CGSize, menuBar: Double, wallpaper: NSImage?) {
        self.store = store
        self.display = display
        self.screen = screen
        self.menuBar = menuBar
        self.wallpaper = wallpaper
    }

    /// Draws the top of the desktop, or its bottom for a bar at the bottom, at the screen's width and `preset`'s
    /// shape. The bar alone gets 120 points of wallpaper beyond it. The wallpaper fills the screen, or the image
    /// when that's taller. Clocks show `fixedDate`, or the time now, and a bar without its own appearance takes
    /// `colorScheme`.
    func draw(fixedDate: Date?, colorScheme: ColorScheme) async {
        png = nil
        let configuration = store.configuration?.onScreen(ScreenKind(display))
        let bottom = configuration?.bar.position == .bottom
        let edge = (bottom ? configuration?.bar.offset : configuration?.bar.top(menuBar: menuBar)) ?? 0
        let strip = edge + (configuration?.barGeometry(for: display).panelHeight ?? 0) + 120
        let pixels = preset.pixels ?? NSSize(width: screen.width * 2, height: strip * 2)
        let size = NSSize(width: screen.width, height: screen.width * pixels.height / pixels.width)
        let dark = (configuration?.bar.appearance?.colorScheme ?? colorScheme) == .dark
        let desktop = BarView(store: store, display: display, preview: true)
            .padding(bottom ? .bottom : .top, edge)
            .frame(width: size.width, height: max(screen.height, size.height))
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
        png = try? await OffscreenSnapshot.png(desktop, size: size, pixels: pixels, dark: dark, settle: .seconds(1), name: "Share My Bar")
    }
}

struct BarShareView: View {
    @Bindable var share: BarShare
    @Environment(\.fixedDate) private var fixedDate
    @Environment(\.colorScheme) private var colorScheme
    @State private var anchor = NSView()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                stage
                Picker("Size", selection: $share.preset) {
                    ForEach(BarSharePreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("Copy Image", action: copy)
                Button("Save Image…", action: save)
                Spacer()
                Button("Share…", action: shareBar)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .background(MenuAnchor(view: anchor))
            }
            .disabled(share.png == nil)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(SettingsPalette.sidebar)
            .overlay(alignment: .top) { SettingsPalette.separator.frame(height: 1) }
        }
        .background(SettingsPalette.background)
        .task(id: share.preset) { await share.draw(fixedDate: fixedDate, colorScheme: colorScheme) }
    }

    /// The image over a blur of itself, so a thin bar strip doesn't float in an empty box.
    private var stage: some View {
        Group {
            if let png = share.png, let image = NSImage(data: png) {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { if let backdrop = share.backdrop { Image(nsImage: backdrop).resizable().scaledToFill().opacity(0.5) } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 300)
        .background(SettingsPalette.stage)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.groupBorder))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(share.png!, forType: .png)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "StableBar.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK else { return }
        do { try share.png!.write(to: panel.url!) } catch { NSAlert(error: error).runModal() }
    }

    private func shareBar() {
        let url = FileManager.default.temporaryDirectory.appending(path: "StableBar.png")
        do {
            try share.png!.write(to: url)
            NSSharingServicePicker(items: [url]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
