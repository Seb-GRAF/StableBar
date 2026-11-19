import AppKit
import Foundation
import SwiftUI

/// A star on GitHub, asked for by the update popup's line and by Star on GitHub in Settings › Help. The line shows until
/// it's dismissed or GitHub says StableBar is starred. With the GitHub CLI signed in, a click stars StableBar through
/// it, as the account the tooltip names; otherwise the click opens the repository, where people press Star themselves.
@MainActor @Observable
final class StarRequest {
    nonisolated static let repositoryPath = "Seb-GRAF/StableBar"
    nonisolated static let repository = URL(string: "https://github.com/\(repositoryPath)")!
    private static let answeredKey = "starRequestAnswered"

    enum State: Equatable {
        /// Waiting for `gh`'s first answer, so the line doesn't appear and then vanish for someone who starred already.
        case checking
        /// Opens the repository: `gh` is missing, signed out or couldn't reach GitHub.
        case repository
        /// Stars StableBar through `gh`, signed in as `account`.
        case gitHubCLI(account: String)
        case starring(account: String)
        /// Starred through `gh` just now. The thanks stays until the popup opens again.
        case thanked(account: String)
        /// Dismissed, or StableBar is starred.
        case answered
    }

    private(set) var state: State
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let gitHub: GitHubStars?
    @ObservationIgnored private var isRefreshing = false

    /// Without `defaults`, the request remembers nothing and asks `gh` even after the popup's ×: Help's Star on GitHub.
    init(defaults: UserDefaults? = .standard, gitHub: GitHubStars = .cli) {
        state = defaults?.bool(forKey: Self.answeredKey) == true ? .answered : .checking
        self.defaults = defaults
        self.gitHub = gitHub
    }

    /// A request in `state` that saves nothing and runs nothing: the scenes' sample.
    init(sample state: State) {
        self.state = state
        defaults = nil
        gitHub = nil
    }

    var isShown: Bool {
        switch state {
        case .checking, .answered: false
        case .repository, .gitHubCLI, .starring, .thanked: true
        }
    }

    var isStarring: Bool {
        if case .starring = state { true } else { false }
    }

    var help: String {
        switch state {
        case let .gitHubCLI(account), let .starring(account): "Stars StableBar as @\(account) with the GitHub CLI"
        default: "Opens StableBar on GitHub"
        }
    }

    /// Asks `gh` whether StableBar is starred, and which account a click would star it as.
    func refresh() async {
        guard let gitHub, !isRefreshing else { return }
        switch state {
        case .answered, .starring: return
        case .thanked:
            state = .answered
            return
        case .checking, .repository, .gitHubCLI: break
        }
        guard gitHub.isInstalled() else {
            state = .repository
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let found = await gitHub.check()
        switch state {
        case .checking, .repository, .gitHubCLI: break
        // A click or × while `gh` answered decides instead.
        case .starring, .thanked, .answered: return
        }
        if let found {
            if found.starred { answer() } else { state = .gitHubCLI(account: found.account) }
        } else {
            state = .repository
        }
    }

    /// Stars StableBar through `gh`, or opens the repository when `gh` can't. A star made elsewhere is unknown
    /// until `gh` reports it, so opening the repository keeps the request.
    func star(open: (URL) -> Void = { NSWorkspace.shared.open($0) }) async {
        guard case let .gitHubCLI(account) = state, let gitHub else {
            open(Self.repository)
            return
        }
        state = .starring(account: account)
        let starred = await gitHub.star()
        guard state == .starring(account: account) else {
            if starred { answer() }
            return
        }
        if starred {
            answer()
            state = .thanked(account: account)
        } else {
            state = .repository
            open(Self.repository)
        }
    }

    func dismiss() {
        answer()
    }

    private func answer() {
        state = .answered
        defaults?.set(true, forKey: Self.answeredKey)
    }
}

/// The user's star through the GitHub CLI on the login shell's PATH, always on github.com, whatever host `gh`
/// defaults to.
struct GitHubStars: Sendable {
    var isInstalled: @Sendable () -> Bool
    /// The signed-in account and whether it starred StableBar, or nil when `gh` is missing, signed out or failed.
    var check: @Sendable () async -> (account: String, starred: Bool)?
    var star: @Sendable () async -> Bool

    static let cli = GitHubStars(
        isInstalled: { executable() != nil },
        check: {
            guard let gh = executable() else { return nil }
            let parts = StarRequest.repositoryPath.split(separator: "/")
            let query = #"query { viewer { login } repository(owner: "\#(parts[0])", name: "\#(parts[1])") { viewerHasStarred } }"#
            guard let output = try? await runCommand(gh.path, arguments: ["api", "--hostname", "github.com", "graphql",
                                                                          "-f", "query=\(query)"]),
                  let reply = try? JSONDecoder().decode(Reply.self, from: output) else { return nil }
            return (reply.data.viewer.login, reply.data.repository.viewerHasStarred)
        },
        star: {
            guard let gh = executable() else { return false }
            return (try? await runCommand(gh.path, arguments: ["api", "--hostname", "github.com", "--method", "PUT", "--silent",
                                                               "user/starred/\(StarRequest.repositoryPath)"])) != nil
        })

    private static func executable() -> URL? {
        executableFile(named: "gh", path: shellEnvironment.withLock { $0["PATH", default: ""] })
    }

    private struct Reply: Decodable {
        struct Viewer: Decodable { let login: String }
        struct Repository: Decodable { let viewerHasStarred: Bool }
        struct Payload: Decodable {
            let viewer: Viewer
            let repository: Repository
        }
        let data: Payload
    }
}

/// The update popup's line asking for a star, in the theme's popup style. × stops the request.
struct StarRequestLine: View {
    let request: StarRequest
    let appearance: WidgetAppearance

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if case let .thanked(account) = request.state {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "star.fill").foregroundStyle(appearance.accent)
                    Text("Thanks for the star, @\(account)!")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            } else {
                Button { Task { await request.star() } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if request.isStarring {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "star.fill").foregroundStyle(appearance.accent)
                        }
                        Text("Enjoying StableBar? Star it on GitHub")
                            .fixedSize(horizontal: false, vertical: true)
                        if request.state == .repository {
                            Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(request.isStarring)
                .help(request.help)
                .accessibilityLabel("Star StableBar on GitHub")
                .accessibilityHint(request.help)
            }
            Spacer(minLength: 0)
            Button(action: request.dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isThanked ? "Close" : "Don't ask again")
            .accessibilityLabel(isThanked ? "Close" : "Don't ask again")
        }
    }

    private var isThanked: Bool {
        if case .thanked = request.state { true } else { false }
    }
}
