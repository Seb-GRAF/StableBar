import AppKit

struct BarDisplay {
    let id: Int
    let isBuiltIn: Bool
    let isMain: Bool
    let notch: ClosedRange<CGFloat>?
    var notchHeight: CGFloat = 0
    let isPortrait: Bool

    init(id: Int, isBuiltIn: Bool, isMain: Bool, notch: ClosedRange<CGFloat>?, isPortrait: Bool = false) {
        self.id = id
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
        self.notch = notch
        self.isPortrait = isPortrait
    }

    init(screen: NSScreen) {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        self.id = NSScreen.screens.firstIndex(of: screen)! + 1
        isBuiltIn = CGDisplayIsBuiltin(id) != 0
        isMain = id == CGMainDisplayID()
        isPortrait = screen.frame.height > screen.frame.width
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = (left.maxX - screen.frame.minX)...(right.minX - screen.frame.minX)
            notchHeight = left.height
        } else {
            notch = nil
        }
    }
}

enum DisplaySelection: Decodable, Equatable, Sendable {
    case all, active, main, builtIn, external, monitor, vertical, notched, unnotched
    case ids([Int])
    /// Screens matching any of these kinds, such as the laptop screen and vertical monitors.
    case any([DisplaySelection])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let ids = try? value.decode([Int].self) {
            self = .ids(ids)
            return
        }
        if let kinds = try? value.decode([DisplaySelection].self) {
            self = .any(kinds)
            return
        }
        switch try value.decode(String.self) {
        case "all": self = .all
        case "active": self = .active
        case "main": self = .main
        case "builtIn": self = .builtIn
        case "external": self = .external
        case "monitor": self = .monitor
        case "vertical": self = .vertical
        case "notched": self = .notched
        case "unnotched": self = .unnotched
        default: throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unknown display selection.")
        }
    }

    func includes(_ display: BarDisplay, activeID: Int) -> Bool {
        switch self {
        case .all: true
        case .active: display.id == activeID
        case .main: display.isMain
        case .builtIn: display.isBuiltIn
        case .external: !display.isBuiltIn
        case .monitor: !display.isBuiltIn && !display.isPortrait
        case .vertical: display.isPortrait
        case .notched: display.notch != nil
        case .unnotched: display.notch == nil
        case let .ids(ids): ids.contains(display.id)
        case let .any(kinds): kinds.contains { $0.includes(display, activeID: activeID) }
        }
    }
}

/// The kinds of screen a setup is made of.
enum ScreenKind: String, CaseIterable {
    case laptop, monitor, vertical

    init(_ display: BarDisplay) {
        self = display.isBuiltIn ? .laptop : display.isPortrait ? .vertical : .monitor
    }

    var title: String {
        switch self {
        case .laptop: "Laptop screen"
        case .monitor: "Landscape monitors"
        case .vertical: "Vertical monitors"
        }
    }

    /// The `display` value that shows a widget on screens of this kind.
    var selection: String {
        switch self {
        case .laptop: "builtIn"
        case .monitor: "monitor"
        case .vertical: "vertical"
        }
    }

    /// Whether a widget shows on this kind of screen: on the connected ones, or on any such screen when none is connected.
    func shows(_ display: DisplaySelection, among displays: [BarDisplay], activeID: Int) -> Bool {
        let connected = displays.filter { ScreenKind($0) == self }
        let screens = connected.isEmpty
            ? [BarDisplay(id: 0, isBuiltIn: self == .laptop, isMain: false, notch: nil, isPortrait: self == .vertical)]
            : connected
        return screens.contains { display.includes($0, activeID: activeID) }
    }
}

/// The screens connected together, such as the laptop with one monitor. A setup can have its own bar in a file
/// beside the main configuration; the others use the main configuration, the shared bar.
struct ScreenSetup: Equatable {
    let kinds: [ScreenKind]

    init(_ displays: [BarDisplay]) {
        kinds = ScreenKind.allCases.flatMap { kind in displays.filter { ScreenKind($0) == kind }.map { _ in kind } }
    }

    init?(fileName: String) {
        guard fileName.hasPrefix("setup-"), fileName.hasSuffix(".json") else { return nil }
        let names = fileName.dropFirst(6).dropLast(5).split(separator: "+")
        let kinds = names.compactMap { ScreenKind(rawValue: String($0)) }
        guard !kinds.isEmpty, kinds.count == names.count else { return nil }
        self.kinds = ScreenKind.allCases.flatMap { kind in kinds.filter { $0 == kind } }
    }

    var fileName: String { "setup-\(kinds.map(\.rawValue).joined(separator: "+")).json" }

    var title: String {
        let parts = ScreenKind.allCases.compactMap { kind -> String? in
            let count = kinds.filter { $0 == kind }.count
            let name = kind == .vertical ? "vertical monitor" : kind.rawValue
            return count == 0 ? nil : count == 1 ? name : "\(count) \(name)s"
        }
        let title = parts.joined(separator: " + ") + (kinds.count == 1 ? " only" : "")
        return title.prefix(1).uppercased() + title.dropFirst()
    }
}

struct BarLayout {
    let inset: CGFloat
    let spacing: CGFloat
    let notchSpacing: CGFloat
    let notch: ClosedRange<CGFloat>?

    func origins(width: CGFloat, sizes: [CGFloat]) -> [CGFloat] {
        var origins: [CGFloat] = [inset, 0, (width - sizes[2]) / 2, 0, width - inset - sizes[4]]
        if let notch {
            origins[1] = notch.lowerBound - notchSpacing - sizes[1]
            origins[3] = notch.upperBound + notchSpacing
        } else {
            let visible = (1...3).filter { sizes[$0] > 0 }
            let total = visible.reduce(CGFloat.zero) { $0 + sizes[$1] } + CGFloat(max(visible.count - 1, 0)) * spacing
            var x = (width - total) / 2
            for index in visible {
                origins[index] = x
                x += sizes[index] + spacing
            }
        }
        return origins
    }
}

/// The band a display's visible frame leaves at its top: the menu bar while it shows, and on a notched
/// display at least the notch. 0 when the menu bar hides or the display has none.
func menuBarHeight(frame: CGRect, visibleFrame: CGRect) -> Double {
    max(0, frame.maxY - visibleFrame.maxY)
}

extension NSScreen {
    var menuBarHeight: Double { StableBar.menuBarHeight(frame: frame, visibleFrame: visibleFrame) }
}
