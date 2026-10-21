import SwiftUI

/// Screen points down from the bar's top. Layout and input retain the visible strip's bounds;
/// the passive decoration panel alone extends beyond the existing bottom margin.
struct BarGeometry: Equatable {
    let layoutHeight: CGFloat
    let margin: CGFloat
    let outsideExtent: CGFloat
    var outsideHeight: CGFloat = 0

    var visibleBottom: CGFloat { layoutHeight - margin }
    /// Opt-out setups retain the original native height, including fractional display scales.
    var inputHeight: CGFloat { outsideExtent > 0 ? roundedEdge(layoutHeight, .up) : layoutHeight }
    var drawingBottom: CGFloat {
        outsideExtent > 0 ? roundedEdge(visibleBottom + outsideExtent - outsideHeight, .up) + roundedEdge(outsideHeight, .up) : visibleBottom
    }
    var panelHeight: CGFloat {
        outsideExtent > 0 ? roundedEdge(max(layoutHeight, drawingBottom), .up) : layoutHeight
    }

    func visibleRect(width: CGFloat) -> CGRect {
        CGRect(x: margin, y: margin, width: max(0, width - 2 * margin), height: max(0, layoutHeight - 2 * margin))
    }
}

extension Configuration {
    func barGeometry(for display: BarDisplay) -> BarGeometry {
        let configuration = onScreen(ScreenKind(display))
        let bar = configuration.bar
        let scale = bar.scale(for: display)
        let bottom = bar.height * scale - bar.margin
        let candidates = configuration.widgets.filter {
            $0.enabled && $0.content == .workspaces && $0.layout == nil
                && $0.display.includes(display, activeID: display.id)
                && $0.workspace?.indicator == .underline
        }.compactMap { $0.workspace?.indicatorStyle.outsideIndicatorBounds }
        let bounds = candidates.max {
            roundedEdge(bottom + $0.gap * scale, .up) + roundedEdge($0.height * scale, .up)
                < roundedEdge(bottom + $1.gap * scale, .up) + roundedEdge($1.height * scale, .up)
        }
        return BarGeometry(layoutHeight: bar.height * scale, margin: bar.margin,
                           outsideExtent: bounds.map { ($0.gap + $0.height) * scale } ?? 0,
                           outsideHeight: bounds.map { $0.height * scale } ?? 0)
    }
}

/// Ignore arithmetic noise near an exact pixel/point (e.g. 50 × 1.1), without rounding a real
/// fractional edge toward the strip. Otherwise ceil could add an entire point of clearance.
private func roundedEdge(_ value: CGFloat, _ rule: FloatingPointRoundingRule) -> CGFloat {
    let nearest = value.rounded()
    return abs(value - nearest) < 1e-9 ? nearest : value.rounded(rule)
}

extension WidgetStyle {
    /// Independent maxima safely cover combinations and nested states (e.g. focused height with
    /// a mode gap) without resizing a panel as states change.
    var maximumOutsideExtent: Double {
        outsideIndicatorBounds.map { $0.height + $0.gap } ?? 0
    }

    var outsideIndicatorBounds: (gap: Double, height: Double)? {
        let variants = allStateStyles
        guard variants.contains(where: { $0.placement == .belowBar }) else { return nil }
        let height = max(0, variants.compactMap(\.height).max() ?? 2, self.height ?? 2)
        let gap = max(0, variants.compactMap(\.offsetY).max() ?? 0)
        return (gap, height)
    }

    private var allStateStyles: [WidgetStyle] {
        [self] + (states ?? [:]).values.flatMap(\.allStateStyles)
    }
}

/// Pixel-aligned drawing bounds. Intersect with the actual widget and its scrolling/group
/// viewport, never the hidden measurement copy or the widget's unconstrained ideal width.
func belowBarIndicatorRect(cell: CGRect, widget: CGRect, viewport: CGRect, visibleBar: CGRect,
                           style: WidgetStyle, scale: CGFloat, pixelsPerPoint: CGFloat) -> CGRect? {
    let left = max(widget.minX, viewport.minX, visibleBar.minX)
    let right = min(widget.maxX, viewport.maxX, visibleBar.maxX)
    guard right > left else { return nil }
    let width = max(0, style.width.map { $0 * scale } ?? cell.width)
    let x = cell.midX - width / 2 + (style.offsetX ?? 0) * scale
    let start = max(left, x)
    let end = min(right, x + width)
    guard end > start else { return nil }
    let pixels = max(1, pixelsPerPoint)
    // Round horizontal edges inward so no partial pixel crosses the owning viewport.
    let minX = roundedEdge(start * pixels, .up) / pixels
    let maxX = roundedEdge(end * pixels, .down) / pixels
    let y = roundedEdge((visibleBar.maxY + (style.offsetY ?? 0) * scale) * pixels, .up) / pixels
    let height = (max(0, style.height ?? 2) * scale * pixels).rounded() / pixels
    guard maxX > minX, height > 0 else { return nil }
    return CGRect(x: minX, y: y, width: maxX - minX, height: height)
}

struct BarWidgetAnchor {
    let bounds: Anchor<CGRect>
    let unit: String
}

struct WorkspaceUnderlineAnchor {
    let widget: String
    let cell: Anchor<CGRect>
    let selection: String
    let style: WidgetStyle
    let color: Color
    let animation: WidgetAnimation
}

struct BarAnchors {
    var widgets: [String: BarWidgetAnchor] = [:]
    var viewports: [String: Anchor<CGRect>] = [:]
    var underlines: [String: WorkspaceUnderlineAnchor] = [:]
}

struct BarAnchorPreference: PreferenceKey {
    static var defaultValue: BarAnchors { BarAnchors() }
    static func reduce(value: inout BarAnchors, nextValue: () -> BarAnchors) {
        let next = nextValue()
        value.widgets.merge(next.widgets) { $1 }
        value.viewports.merge(next.viewports) { $1 }
        value.underlines.merge(next.underlines) { $1 }
    }
}

private struct BarUnitIDKey: EnvironmentKey { static let defaultValue = "" }
private struct ScreenKindKey: EnvironmentKey { static let defaultValue = ScreenKind.laptop }

extension EnvironmentValues {
    var screenKind: ScreenKind {
        get { self[ScreenKindKey.self] }
        set { self[ScreenKindKey.self] = newValue }
    }

    var barUnitID: String {
        get { self[BarUnitIDKey.self] }
        set { self[BarUnitIDKey.self] = newValue }
    }
}

struct WorkspaceUnderline: Identifiable {
    let id: String
    let selection: String
    let rect: CGRect
    let style: WidgetStyle
    let color: Color
    let animation: WidgetAnimation
    let scale: CGFloat
}

struct WorkspaceDecorationCanvas: View {
    let underlines: [WorkspaceUnderline]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(underlines) { underline in
                RoundedRectangle(cornerRadius: max(0, underline.style.cornerRadius ?? 0) * underline.scale)
                    .fill(underline.color)
                    .frame(width: underline.rect.width, height: underline.rect.height)
                    .opacity(underline.style.opacity ?? 1)
                    .offset(x: underline.rect.minX, y: underline.rect.minY)
                    // Only selection changes add animation. Scrolling and unrelated layout
                    // changes stay locked to their cells and inherit the enclosing transaction.
                    .animation(reduceMotion ? nil : underline.animation.value, value: underline.selection)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct BarDecorations: View {
    let anchors: BarAnchors
    let geometry: BarGeometry
    let scale: CGFloat
    var native = false
    @Environment(\.displayScale) private var pixelsPerPoint
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let visible = geometry.visibleRect(width: proxy.size.width)
            let underlines = anchors.underlines.keys.sorted().compactMap { id -> WorkspaceUnderline? in
                guard let underline = anchors.underlines[id], let widget = anchors.widgets[underline.widget],
                      let rect = belowBarIndicatorRect(cell: proxy[underline.cell], widget: proxy[widget.bounds],
                          viewport: anchors.viewports[widget.unit].map { proxy[$0] } ?? visible,
                          visibleBar: visible, style: underline.style, scale: scale, pixelsPerPoint: pixelsPerPoint) else { return nil }
                return WorkspaceUnderline(id: id, selection: underline.selection, rect: rect, style: underline.style,
                                          color: underline.color, animation: underline.animation, scale: scale)
            }
            if native {
                NativeBarDecorations(underlines: underlines, size: CGSize(width: proxy.size.width, height: geometry.panelHeight),
                                     colorScheme: colorScheme, displayScale: pixelsPerPoint)
            } else {
                WorkspaceDecorationCanvas(underlines: underlines)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct BarDecorationLayer: ViewModifier {
    let geometry: BarGeometry
    let scale: CGFloat
    let native: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if geometry.outsideExtent > 0 {
            content.overlayPreferenceValue(BarAnchorPreference.self) { anchors in
                BarDecorations(anchors: anchors, geometry: geometry, scale: scale, native: native)
            }
        } else {
            content
        }
    }
}

/// The opening instance supplies both its anchor and window; never use NSScreen.main here.
func popupAttachmentTop(anchor: CGRect, window: CGRect, geometry: BarGeometry?) -> CGFloat {
    guard let geometry else { return anchor.minY }
    return window.maxY - geometry.drawingBottom
}
