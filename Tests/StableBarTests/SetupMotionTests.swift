import SwiftUI
import Testing
@testable import StableBar

struct SetupMotionTests {
    @Test(arguments: [0.0, 0.08, 0.16])
    func reducedMotionRevealsEveryStageAfterRemoval(delay: Double) {
        let motion = SetupMotion(reduceMotion: true)
        #expect(motion.stepEffect == .fade)
        #expect(motion.stepAnimation == nil)
        #expect(motion.revealAnimation(delay: delay) == .easeOut(duration: 0.2).delay(0.2))
        #expect(motion.removalAnimation == .easeOut(duration: 0.2))
    }

    @Test(arguments: [0.0, 0.08, 0.16])
    func fullMotionKeepsTheStaggeredBlurAndSlide(delay: Double) {
        let motion = SetupMotion(reduceMotion: false)
        #expect(motion.stepEffect == .blurSlide)
        #expect(motion.stepAnimation == .smooth(duration: 0.5))
        #expect(motion.revealAnimation(delay: delay) == .smooth(duration: 0.5).delay(0.22 + delay))
        #expect(motion.removalAnimation == .easeIn(duration: 0.2))
    }

    @Test(arguments: [false, true])
    func scrollingAndFeedbackMoveOnlyWithoutReduceMotion(reduceMotion: Bool) {
        let motion = SetupMotion(reduceMotion: reduceMotion)
        #expect(motion.movement(.smooth(duration: 0.3)) == (reduceMotion ? nil : .smooth(duration: 0.3)))
        #expect(motion.movement(.snappy) == (reduceMotion ? nil : .snappy))
        for scale in [CGFloat(0.97), CGFloat(1.02)] {
            #expect(motion.scale(true, to: scale) == (reduceMotion ? 1 : scale))
            #expect(motion.scale(false, to: scale) == 1)
        }
        #expect(motion.cardAnimationBehavior == (reduceMotion ? .none : .alertPanel))
    }

    @Test(arguments: [false, true], [false, true])
    func controlsCannotIntroduceMovementWhenMotionIsReduced(reduceMotion: Bool, animationsAlreadyDisabled: Bool) {
        let motion = SetupMotion(reduceMotion: reduceMotion)
        var transaction = Transaction(animation: .snappy)
        transaction.disablesAnimations = animationsAlreadyDisabled
        motion.suppressMovement(in: &transaction)
        #expect(transaction.animation == (reduceMotion ? nil : .snappy))
        #expect(transaction.disablesAnimations == (reduceMotion || animationsAlreadyDisabled))
    }
}
