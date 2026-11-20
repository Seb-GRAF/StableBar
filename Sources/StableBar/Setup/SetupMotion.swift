import SwiftUI

/// Setup keeps fades with Reduce Motion, but changes geometry immediately. Views resolve this from their live
/// accessibility environment, rather than keeping the setting from when setup opened.
struct SetupMotion {
    enum StepEffect { case fade, rise }

    let reduceMotion: Bool

    var stepEffect: StepEffect { reduceMotion ? .fade : .rise }
    /// The bar gliding between its places on the stage, and to the top edge.
    var stageAnimation: Animation { reduceMotion ? .easeInOut(duration: 0.35) : .spring(duration: 0.85, bounce: 0.16) }

    func revealAnimation(delay: Double) -> Animation {
        // A departing step keeps its layout space until its fade ends.
        // Let that settle before fading in the new step.
        reduceMotion ? .easeOut(duration: 0.2).delay(0.2) : .smooth(duration: 0.5).delay(0.22 + delay)
    }

    var removalAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .easeIn(duration: 0.2)
    }

    /// Steps fade and drift; they never blur, which would redraw the whole screen every frame.
    func stepTransition(delay: Double) -> AnyTransition {
        let insertion: AnyTransition
        let removal: AnyTransition
        switch stepEffect {
        case .fade:
            insertion = .opacity
            removal = .opacity
        case .rise:
            insertion = .opacity.combined(with: .offset(y: 14))
            removal = .opacity.combined(with: .offset(y: -8))
        }
        return .asymmetric(insertion: insertion.animation(revealAnimation(delay: delay)),
                           removal: removal.animation(removalAnimation))
    }

    func movement(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Where the intro is `time` seconds after it starts. The wallpaper fades in sharp and settles from a slight zoom, then
/// dims and softens as StableBar's name rises under a sweep of light; a glowing line widens from the middle and the bar
/// opens out of it, its widgets showing from left to right. With Reduce Motion, each of them fades in where it rests.
struct SetupIntro {
    let reduceMotion: Bool
    let time: Double

    var length: Double { reduceMotion ? 1.5 : 2.7 }
    /// The wallpaper's opacity, and its scale as it settles.
    var wallpaper: Double { fade(0, reduceMotion ? 0.5 : 0.7) }
    var zoom: Double { reduceMotion ? 1 : 1 + 0.08 * (1 - Self.settle.value(at: progress(time, 0, 1.2))) }
    /// How far the wallpaper has dimmed and softened.
    var softness: Double { reduceMotion ? progress(time, 0.5, 0.6) : UnitCurve.easeInOut.value(at: progress(time, 0.85, 0.8)) }
    var name: Double { fade(reduceMotion ? 0.6 : 1.0, 0.75) }
    var nameRise: Double { reduceMotion ? 0 : 18 * (1 - name) }
    /// Where the light crosses the name, from 0 to 1; it stays off with Reduce Motion.
    var sweep: Double { reduceMotion ? 0 : UnitCurve.easeInOut.value(at: progress(time, 1.3, 0.9)) }
    /// How wide the glowing line has grown, and how bright it is.
    var line: Double { reduceMotion ? 0 : Self.settle.value(at: progress(time, 1.45, 0.55)) }
    var glow: Double { reduceMotion ? 0 : progress(time, 1.45, 0.15) * (1 - progress(time, 2.05, 0.45)) }
    /// The bar's height as it opens from the line, as a fraction of its own, and its opacity.
    var open: Double { reduceMotion || time >= 2.6 ? 1 : time < 1.85 ? 0.04 : 0.04 + 0.96 * Self.opening.value(target: 1.0, time: time - 1.85) }
    var bar: Double { reduceMotion ? progress(time, 0.8, 0.5) : progress(time, 1.8, 0.12) }
    /// How far across the bar its widgets show.
    var widgets: Double { reduceMotion ? 1 : UnitCurve.easeInOut.value(at: progress(time, 1.95, 0.65)) }
    /// The tagline and Get Started.
    var invitation: Double { fade(reduceMotion ? 1.0 : 2.2, reduceMotion ? 0.4 : 0.5) }

    /// Fast out, long settle.
    private static let settle = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.16, y: 1), endControlPoint: UnitPoint(x: 0.3, y: 1))
    private static let opening = Spring(duration: 0.55, bounce: 0.18)

    private func fade(_ start: Double, _ duration: Double) -> Double {
        reduceMotion ? progress(time, start, duration) : Self.settle.value(at: progress(time, start, duration))
    }
}

/// How far `time` is through the span that begins at `start` and lasts `duration`, from 0 to 1.
func progress(_ time: Double, _ start: Double, _ duration: Double) -> Double {
    min(max((time - start) / duration, 0), 1)
}
