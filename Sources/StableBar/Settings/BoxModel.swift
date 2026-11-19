import SwiftUI

struct BoxModel: View {
    let style: StyleFields
    let name: String

    var body: some View {
        let horizontal = style.numberBinding("paddingHorizontal", default: 10)
        let vertical = style.numberBinding("paddingVertical", default: 6)
        let corner = style.numberBinding("cornerRadius", default: 14)
        VStack(spacing: 6) {
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(SettingsPalette.groupBorder))
                .padding(.horizontal, horizontal.wrappedValue * 1.5)
                .padding(.vertical, vertical.wrappedValue * 1.5)
                .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: corner.wrappedValue))
                .overlay(RoundedRectangle(cornerRadius: corner.wrappedValue).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .leading) { field("Horizontal padding", "paddingHorizontal", horizontal, symbol: "arrow.left.and.right") }
                .overlay(alignment: .trailing) { field("Horizontal padding", "paddingHorizontal", horizontal, symbol: "arrow.left.and.right") }
                .overlay(alignment: .top) { field("Vertical padding", "paddingVertical", vertical, symbol: "arrow.up.and.down") }
                .overlay(alignment: .bottom) { field("Vertical padding", "paddingVertical", vertical, symbol: "arrow.up.and.down") }
                .overlay(alignment: .topLeading) { field("Corner radius", "cornerRadius", corner, symbol: "square.dashed") }
                .frame(height: 150)
            HStack(spacing: 12) {
                Label("horizontal padding", systemImage: "arrow.left.and.right")
                Label("vertical padding", systemImage: "arrow.up.and.down")
                Label("corner radius", systemImage: "square.dashed")
                Text("Drag a symbol, or use ↑ ↓ in a field").foregroundStyle(.tertiary)
            }
            .labelStyle(LegendLabelStyle())
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .groupRow()
    }

    private func field(_ title: String, _ key: String, _ value: Binding<Double>, symbol: String) -> some View {
        let property = style.property(key)
        return HStack(spacing: 4) {
            RevertSettingButton(title: title, property: property, reset: property.saved.map { source in { style.reset(source) } })
            NumberDraft(value: value) { NumberField(title: title, value: $0, range: 0...30, unit: "", symbol: symbol) }
        }
        .padding(4)
        .help(title)
    }
}

private struct LegendLabelStyle: LabelStyle {
    func makeBody(configuration: LabelStyleConfiguration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .semibold))
            configuration.title
        }
    }
}
