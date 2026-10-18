import SwiftUI

private struct StaticPreviewDateKey: EnvironmentKey { static let defaultValue: Date? = nil }
extension EnvironmentValues {
    var staticPreviewDate: Date? {
        get { self[StaticPreviewDateKey.self] }
        set { self[StaticPreviewDateKey.self] = newValue }
    }
}

struct ThemeCard: View {
    let title: String
    let snapshot: ThemePreview.Snapshot?
    var isSelected = false
    var progress: String?
    var error: String?
    var isStore = false
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isStore {
                preview
                HStack {
                    Text(title).font(.callout).lineLimit(1)
                    Spacer()
                    if let progress {
                        ProgressView().controlSize(.small)
                        Text(progress).font(.caption).lineLimit(1)
                    } else {
                        Button("Get", action: select).accessibilityLabel("Get \(title)")
                    }
                }
            } else {
                Button(action: select) {
                    VStack(alignment: .leading, spacing: 8) {
                        preview
                        HStack {
                            Text(title).lineLimit(1)
                            if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                        }.font(.callout)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title) theme")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    @Environment(\.colorScheme) private var colorScheme

    var previewColorScheme: ColorScheme {
        guard let snapshot, let configuration = snapshot.store.configuration else { return colorScheme }
        return ThemePreview.usesDarkAppearance(configuration, context: snapshot.store.context) ? .dark : .light
    }

    private var preview: some View {
        Group {
            if let snapshot, snapshot.store.configuration != nil {
                ThemeBarThumbnail(store: snapshot.store, date: snapshot.date)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .overlay { Text(isStore && error == nil ? "Loading preview…" : "Preview unavailable").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(height: 76)
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isSelected ? 2 : 1)
        }
        .environment(\.colorScheme, previewColorScheme)
        .accessibilityHidden(true)
    }
}

struct ThemePreviewSizing {
    static let minimumScale: CGFloat = 0.5
    let width: CGFloat
    let scale: CGFloat
    let clipsMiddle: Bool
    let isMeasured: Bool

    init(naturalSize: CGSize, availableWidth: CGFloat) {
        let naturalWidth = naturalSize.width
        let width = max(0, availableWidth)
        self.width = max(naturalWidth, width)
        scale = naturalWidth > 0 ? min(1, max(Self.minimumScale, width / naturalWidth)) : 1
        clipsMiddle = naturalWidth * Self.minimumScale > width
        isMeasured = naturalSize.height > 0
    }
}

private struct ThemePreviewSize: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct ThemeBarThumbnail: View {
    let store: BarStore
    let date: Date
    @State private var naturalSize: CGSize = .zero

    var body: some View {
        GeometryReader { viewport in
            let sizing = ThemePreviewSizing(naturalSize: naturalSize, availableWidth: viewport.size.width)
            Group {
                if sizing.clipsMiddle {
                    HStack(spacing: 0) {
                        end(sizing: sizing, size: viewport.size, leading: true)
                        end(sizing: sizing, size: viewport.size, leading: false)
                    }
                } else {
                    scaledBar(sizing)
                        .frame(width: viewport.size.width, height: viewport.size.height)
                }
            }
            .opacity(sizing.isMeasured ? 1 : 0)
        }
        .overlay {
            ThemeBarPreview(store: store, date: date)
                .fixedSize()
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ThemePreviewSize.self, value: geometry.size)
                    }
                }
                .hidden()
                .accessibilityHidden(true)
                .modifier(MeasuringCopy())
        }
        .onPreferenceChange(ThemePreviewSize.self) { naturalSize = $0 }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .clipped()
        .allowsHitTesting(false)
    }

    private func scaledBar(_ sizing: ThemePreviewSizing) -> some View {
        ThemeBarPreview(store: store, date: date, width: sizing.width)
            .fixedSize()
            .scaleEffect(sizing.scale)
            .frame(width: sizing.width * sizing.scale, height: naturalSize.height * sizing.scale)
    }

    private func end(sizing: ThemePreviewSizing, size: CGSize, leading: Bool) -> some View {
        let width = size.width / 2
        let fade = min(16, width) / max(1, width)
        return scaledBar(sizing)
            .frame(width: width, height: size.height, alignment: leading ? .leading : .trailing)
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 1 - fade),
                                       .init(color: .clear, location: 1)],
                               startPoint: leading ? .leading : .trailing, endPoint: leading ? .trailing : .leading)
            }
    }
}

private struct ThemeBarPreview: View {
    let store: BarStore
    let date: Date
    var width: CGFloat?

    var body: some View {
        if let configuration = store.configuration {
            let display = ThemePreview.display(for: store)
            let geometry = configuration.barGeometry(for: display)
            let units = ThemePreview.units(in: store, display: display)
            ThemeBarPreviewLayout(positions: units.map(\.position), spacing: configuration.bar.spacing) {
                ForEach(units) { unit in
                    BarUnitView(unit: unit, config: configuration, store: store, display: display.id)
                        .lineLimit(1)
                        .transformAnchorPreference(key: BarAnchorPreference.self, value: .bounds) { anchors, bounds in
                            anchors.viewports[unit.id] = bounds
                        }
                }
            }
            .padding(.horizontal, configuration.bar.inset)
            .frame(width: width.map { max(0, $0 - 2 * configuration.bar.margin) })
            .frame(height: max(0, configuration.bar.height - 2 * configuration.bar.margin))
            .modifier(BarSurface(store: store, settings: configuration.bar))
            .padding(configuration.bar.margin)
            .modifier(BarDecorationLayer(geometry: geometry, scale: 1, native: false))
            .frame(height: geometry.panelHeight, alignment: .top)
            .environment(\.staticPreviewDate, date)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            .allowsHitTesting(false)
        }
    }
}

struct ThemeBarPreviewLayout: Layout {
    let positions: [WidgetPosition]
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * spacing
        return CGSize(width: max(naturalWidth, proposal.width ?? 0), height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = plan(width: bounds.width, widths: subviews.map { $0.sizeThatFits(.unspecified).width })
        for (index, subview) in subviews.enumerated() {
            if let placement = plan.placements[String(index)] {
                subview.place(at: CGPoint(x: bounds.minX + placement.x, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: placement.width, height: bounds.height))
            }
        }
    }

    func plan(width: CGFloat, widths: [CGFloat]) -> AdaptiveBarPlan {
        let items = zip(positions, widths).enumerated().map { index, item in
            BarLayoutItem(id: String(index), position: item.0, width: item.1, canOverflow: false)
        }
        return AdaptiveBarPlanner(inset: 0, spacing: spacing, notchSpacing: 0, notch: nil).plan(width: width, items: items)
    }
}
