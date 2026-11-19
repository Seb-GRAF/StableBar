import SwiftUI

/// Setup keeps fades with Reduce Motion, but changes geometry immediately. Views resolve this from their live
/// accessibility environment, rather than keeping the setting from when setup opened.
struct SetupMotion {
    enum StepEffect { case fade, blurSlide }

    let reduceMotion: Bool

    var stepEffect: StepEffect { reduceMotion ? .fade : .blurSlide }
    /// Only the transition animates under Reduce Motion, so the surrounding layout doesn't move with it.
    var stepAnimation: Animation? { movement(.smooth(duration: 0.5)) }

    func revealAnimation(delay: Double) -> Animation {
        // A departing step keeps its layout space until its fade ends.
        // Let that settle before fading in the new step.
        reduceMotion ? .easeOut(duration: 0.2).delay(0.2) : .smooth(duration: 0.5).delay(0.22 + delay)
    }

    var removalAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .easeIn(duration: 0.2)
    }

    func stepTransition(delay: Double) -> AnyTransition {
        let insertion: AnyTransition
        let removal: AnyTransition
        switch stepEffect {
        case .fade:
            insertion = .opacity
            removal = .opacity
        case .blurSlide:
            insertion = .blurFade.combined(with: .offset(y: 12))
            removal = .blurFade.combined(with: .offset(y: -8))
        }
        return .asymmetric(insertion: insertion.animation(revealAnimation(delay: delay)),
                           removal: removal.animation(removalAnimation))
    }

    func movement(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    func scale(_ active: Bool, to scale: CGFloat) -> CGFloat {
        active && !reduceMotion ? scale : 1
    }

    /// A step's controls can start their own animations (including matched geometry in segmented controls).
    /// Keep those and permission-row layout changes still, inside the step's outer fade transition.
    func suppressMovement(in transaction: inout Transaction) {
        guard reduceMotion else { return }
        transaction.animation = nil
        transaction.disablesAnimations = true
    }

    var cardAnimationBehavior: NSWindow.AnimationBehavior { reduceMotion ? .none : .alertPanel }
}
