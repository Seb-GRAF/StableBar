import AppKit
import SwiftUI

@MainActor @Observable
final class WorkspaceMagnifier {
    private(set) var pointer: CGFloat = 0
    private(set) var isActive = false

    func track(_ phase: HoverPhase) {
        switch phase {
        case let .active(location):
            pointer = location.x
            isActive = true
        case .ended:
            isActive = false
        }
    }
}

struct WorkspaceStretch {
    static let reach: CGFloat = 36
    static let iconShare: CGFloat = 0.8

    let pointer: CGFloat
    let maximum: CGFloat
    let amount: CGFloat

    func scale(at x: CGFloat) -> CGFloat {
        let distance = abs(x - pointer)
        guard distance < Self.reach else { return 1 }
        return 1 + (maximum - 1) * amount * (1 + cos(.pi * distance / Self.reach)) / 2
    }

    func shift(at x: CGFloat) -> CGFloat {
        let distance = min(abs(x - pointer), Self.reach)
        let stretch = distance / 2 + Self.reach / (2 * .pi) * sin(.pi * distance / Self.reach)
        return Self.iconShare * (maximum - 1) * amount * stretch * (x < pointer ? -1 : 1)
    }
}

struct WorkspaceMagnification: ViewModifier {
    enum Part {
        case icon
        case label
        case background
    }

    let magnifier: WorkspaceMagnifier
    let part: Part
    let maximum: CGFloat
    @State private var frame = CGRect.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        let stretched = Stretched(part: part, frame: frame, pointer: magnifier.pointer, maximum: maximum,
                                  amount: magnifier.isActive ? 1 : 0)
        let animation: Animation? = reduceMotion ? nil : .smooth(duration: 0.25)
        if part == .background {
            content
                .modifier(stretched)
                .animation(animation, value: magnifier.isActive)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        } else {
            content
                .modifier(stretched)
                .animation(animation, value: magnifier.isActive)
        }
    }
}

private struct Stretched: ViewModifier, Animatable {
    let part: WorkspaceMagnification.Part
    let frame: CGRect
    let pointer: CGFloat
    let maximum: CGFloat
    var amount: CGFloat

    nonisolated var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    @ViewBuilder func body(content: Content) -> some View {
        let stretch = WorkspaceStretch(pointer: pointer, maximum: maximum, amount: amount)
        switch part {
        case .icon:
            content.visualEffect { content, geometry in
                let midX = geometry.frame(in: .global).midX
                return content
                    .scaleEffect(stretch.scale(at: midX), anchor: .top)
                    .offset(x: stretch.shift(at: midX))
            }
        case .label:
            content.visualEffect { content, geometry in
                content.offset(x: stretch.shift(at: geometry.frame(in: .global).midX))
            }
        case .background:
            content
                .padding(.leading, stretch.shift(at: frame.minX))
                .padding(.trailing, -stretch.shift(at: frame.maxX))
        }
    }
}

struct AppNameTooltip: ViewModifier {
    let name: String
    let magnifier: WorkspaceMagnifier
    let spacing: CGFloat
    let hover: (Bool, String, NSView) -> Void
    @State private var anchor = NSView()
    @State private var frame = CGRect.zero

    func body(content: Content) -> some View {
        let over = magnifier.isActive && abs(magnifier.pointer - frame.midX) <= (frame.width + spacing) / 2
        content
            .background(MenuAnchor(view: anchor))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .task(id: over) {
                if over { do { try await Task.sleep(for: .milliseconds(100)) } catch { return } }
                hover(over, name, anchor)
            }
            .onDisappear { hover(false, name, anchor) }
    }
}

extension View {
    @ViewBuilder func magnified(_ part: WorkspaceMagnification.Part, by magnifier: WorkspaceMagnifier,
                                upTo maximum: CGFloat?) -> some View {
        if let maximum { modifier(WorkspaceMagnification(magnifier: magnifier, part: part, maximum: maximum)) } else { self }
    }
}
