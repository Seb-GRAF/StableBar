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
                    Text(title).font(.callout)
                    Spacer()
                    if let progress {
                        ProgressView().controlSize(.small)
                        Text(progress).font(.caption)
                    } else {
                        Button("Get", action: select).accessibilityLabel("Get \(title)")
                    }
                }
            } else {
                Button(action: select) {
                    VStack(alignment: .leading, spacing: 8) {
                        preview
                        HStack {
                            Text(title)
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
    }

    private var preview: some View {
        Group {
            if let snapshot, let configuration = snapshot.store.configuration {
                ThemeBarPreview(store: snapshot.store, date: snapshot.date)
                    .environment(\.colorScheme, ThemePreview.usesDarkAppearance(configuration, context: snapshot.store.context) ? .dark : .light)
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
        .accessibilityHidden(true)
    }
}

private struct ThemeBarPreview: View {
    let store: BarStore
    let date: Date

    var body: some View {
        if let configuration = store.configuration {
            let display = ThemePreview.display(for: store)
            let geometry = configuration.barGeometry(for: display)
            HStack(spacing: configuration.bar.spacing) {
                ForEach(ThemePreview.units(in: store, display: display)) { unit in
                    BarUnitView(unit: unit, config: configuration, store: store, display: display.id)
                        .lineLimit(1)
                        .transformAnchorPreference(key: BarAnchorPreference.self, value: .bounds) { anchors, bounds in
                            anchors.viewports[unit.id] = bounds
                        }
                }
            }
            .padding(.horizontal, configuration.bar.inset)
            .frame(maxWidth: .infinity)
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
