import AppKit
import Foundation
import SwiftUI

/// The one-time line in the update popup that asks for a star on GitHub. It shows from a week after
/// StableBar first ran with it, and never again once it's clicked or dismissed. Nothing is starred for
/// the user: the line opens the repository, where they press Star themselves.
@MainActor @Observable
final class StarRequest {
    static let repository = URL(string: "https://github.com/Seb-GRAF/StableBar")!
    static let wait: TimeInterval = 7 * 24 * 60 * 60
    private static let startKey = "starRequestStart"
    private static let answeredKey = "starRequestAnswered"

    private(set) var isAnswered: Bool
    @ObservationIgnored private let start: Date
    @ObservationIgnored private let defaults: UserDefaults?

    /// The request saved in `defaults`, which starts its wait at `now` the first time.
    init(defaults: UserDefaults = .standard, now: Date = .now) {
        if defaults.object(forKey: Self.startKey) as? Date == nil {
            defaults.set(now, forKey: Self.startKey)
        }
        start = defaults.object(forKey: Self.startKey) as? Date ?? now
        isAnswered = defaults.bool(forKey: Self.answeredKey)
        self.defaults = defaults
    }

    /// A request that saves nothing, waiting since `start`: the scenes' sample.
    init(start: Date) {
        self.start = start
        isAnswered = false
        defaults = nil
    }

    func isDue(at now: Date = .now) -> Bool {
        !isAnswered && now.timeIntervalSince(start) >= Self.wait
    }

    /// Opens the repository and stops asking.
    func star(open: (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        dismiss()
        open(Self.repository)
    }

    func dismiss() {
        isAnswered = true
        defaults?.set(true, forKey: Self.answeredKey)
    }
}

/// The update popup's line asking for a star, in the theme's popup style: the line opens the repository,
/// and × dismisses it. Either answer stops the request.
struct StarRequestLine: View {
    let request: StarRequest
    let appearance: WidgetAppearance

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button { request.star() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "star.fill").foregroundStyle(appearance.accent)
                    Text("Enjoying StableBar? Star it on GitHub")
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Star StableBar on GitHub")
            Spacer(minLength: 0)
            Button(action: request.dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Don't ask again")
            .accessibilityLabel("Don't ask again")
        }
    }
}
