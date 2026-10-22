import SwiftUI

struct HoverExpansionLayout: Layout {
    var expansion: CGFloat
    let spacing: CGFloat
    let controlsBefore: Bool

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let controls = subviews[0].sizeThatFits(.unspecified)
        let label = subviews[1].sizeThatFits(.unspecified)
        return CGSize(width: label.width + (controls.width + spacing) * expansion,
                      height: max(controls.height, label.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let controls = subviews[0].sizeThatFits(.unspecified)
        let label = subviews[1].sizeThatFits(.unspecified)
        if controlsBefore {
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(label))
            subviews[0].place(at: CGPoint(x: bounds.maxX - label.width - spacing, y: bounds.midY),
                              anchor: .trailing, proposal: ProposedViewSize(controls))
        } else {
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(label))
            subviews[0].place(at: CGPoint(x: bounds.minX + label.width + spacing, y: bounds.midY),
                              anchor: .leading, proposal: ProposedViewSize(controls))
        }
    }
}
