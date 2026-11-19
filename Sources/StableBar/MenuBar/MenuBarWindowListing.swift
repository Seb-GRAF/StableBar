import CoreGraphics
import Foundation

/// Which of MenuBarAgent's windows a live item is copied from. A listed window keeps the frame it had when listed, and
/// MenuBarAgent resizes the same window when displays change; a capture at the old size is scaled, which moves every
/// item's copy. So a window is captured only while its frame is still the listed one, and is listed again otherwise.
struct MenuBarWindowListing: StateMachine {
    struct Window {
        let id: CGWindowID
        let frame: CGRect
    }

    enum Event {
        /// Time to copy the items, the first one's middle at `point`; `current` holds the listed windows' frames now.
        case refresh(point: CGPoint, current: [CGWindowID: CGRect], at: Date)
        case listed([Window])
        /// A window couldn't be captured, as after MenuBarAgent restarts.
        case captureFailed
    }

    enum Effect: Equatable {
        /// Lists the windows, then sends `listed`.
        case list
        /// Captures these windows in order until one holds the items. A display can have a second menu bar window that
        /// holds none.
        case capture([CGWindowID])
    }

    /// Listing the windows takes about half a second of the window server's time, so it waits between tries.
    static let listingInterval: TimeInterval = 10

    private(set) var windows: [Window] = []
    private var nextListing = Date.distantPast
    private var point: CGPoint?

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .refresh(let point, let current, let now):
            self.point = point
            let containing = windows.filter { $0.frame.contains(point) }
            let unchanged = containing.filter { isCurrent($0.frame, current[$0.id]) }
            if unchanged.count < containing.count || containing.isEmpty, now >= nextListing {
                nextListing = now.addingTimeInterval(Self.listingInterval)
                return [.list]
            }
            return unchanged.isEmpty ? [] : [.capture(unchanged.map(\.id))]
        case .listed(let windows):
            self.windows = windows
            guard let point else { return [] }
            let containing = windows.filter { $0.frame.contains(point) }
            return containing.isEmpty ? [] : [.capture(containing.map(\.id))]
        case .captureFailed:
            windows = []
            return []
        }
    }
}

/// Whether a window listed at `listed` still has that frame. A window the window server no longer knows has none.
func isCurrent(_ listed: CGRect, _ current: CGRect?) -> Bool {
    guard let current else { return false }
    return abs(listed.minX - current.minX) < 0.5 && abs(listed.minY - current.minY) < 0.5
        && abs(listed.width - current.width) < 0.5 && abs(listed.height - current.height) < 0.5
}
