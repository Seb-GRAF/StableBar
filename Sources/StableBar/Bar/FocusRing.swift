import SwiftUI

/// Shows keyboard focus as macOS does, with a ring around the view that `ring` draws.
struct FocusRing<Ring: View>: ViewModifier {
    let ring: Ring
    @FocusState private var focused: Bool

    init(@ViewBuilder ring: () -> Ring) {
        self.ring = ring()
    }

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .overlay { if focused { ring } }
    }
}

extension FocusRing where Ring == FocusRingShape<RoundedRectangle> {
    /// A ring 4 points around the view, its corners concentric with corners of `cornerRadius`.
    init(cornerRadius: Double) {
        self.init { FocusRingShape(shape: RoundedRectangle(cornerRadius: cornerRadius + 4)) }
    }
}

/// A 2-point ring along `shape` in the tint, which a popup sets to the theme's accent, reaching `outset` points past the
/// view: 4 leaves a gap around a control's own outline, and 0 keeps it inside a row, whose neighbors leave no room.
struct FocusRingShape<S: InsettableShape>: View {
    let shape: S
    var outset = 4.0

    var body: some View {
        shape.strokeBorder(.tint, lineWidth: 2).padding(-outset)
    }
}
