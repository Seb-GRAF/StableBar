import SwiftUI

/// Lays out a tray's widgets left to right, continuing on a new row when the next one doesn't fit the
/// proposed width, so a crowded position keeps every widget in reach while editing. Without a width, as
/// in the measuring copy, everything stays on one row. Each row centers its widgets vertically, like the bar.
struct BarEditFlow: Layout {
    var rowSpacing: CGFloat

    /// The items on each row. An item wider than `width` gets a row of its own; an item without width,
    /// such as a widget collapsed while it's dragged elsewhere, stays on the row before it.
    static func rows(_ widths: [CGFloat], fitting width: CGFloat?) -> [Range<Int>] {
        var rows: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for (index, itemWidth) in widths.enumerated() {
            if let width, index > start, itemWidth > 0, used + itemWidth > width + 0.5 {
                rows.append(start..<index)
                start = index
                used = 0
            }
            used += itemWidth
        }
        if start < widths.count { rows.append(start..<widths.count) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = Self.sizes(of: subviews, fitting: Self.width(of: proposal))
        let rows = Self.rows(sizes.map(\.width), fitting: Self.width(of: proposal))
        let width = rows.map { sizes[$0].reduce(0) { $0 + $1.width } }.max() ?? 0
        let height = rows.reduce(0) { $0 + (sizes[$1].map(\.height).max() ?? 0) } + CGFloat(max(rows.count - 1, 0)) * rowSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = Self.sizes(of: subviews, fitting: Self.width(of: proposal))
        var y = bounds.minY
        for row in Self.rows(sizes.map(\.width), fitting: Self.width(of: proposal)) {
            let height = sizes[row].map(\.height).max() ?? 0
            var x = bounds.minX
            for index in row {
                subviews[index].place(at: CGPoint(x: x, y: y + height / 2), anchor: .leading, proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width
            }
            y += height + rowSpacing
        }
    }

    /// Each item's own size, no wider than `width`: an item wider than the tray scrolls inside it.
    private static func sizes(of subviews: Subviews, fitting width: CGFloat?) -> [CGSize] {
        subviews.map { subview in
            let size = subview.sizeThatFits(.unspecified)
            return CGSize(width: min(size.width, width ?? size.width), height: size.height)
        }
    }

    private static func width(of proposal: ProposedViewSize) -> CGFloat? {
        proposal.width.flatMap { $0.isFinite ? $0 : nil }
    }
}
