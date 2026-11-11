import Foundation

/// What Send feedback in Settings › Status turns into an issue: a bug or an idea, in the fields of the matching
/// GitHub issue form. A bug also carries the bug report as Environment and the chosen crash as Evidence.
struct Feedback {
    enum Kind {
        case bug, idea

        var template: String { self == .bug ? "bug_report.yml" : "feature_request.yml" }

        /// The fields the user writes, as the form in `.github/ISSUE_TEMPLATE` names and describes them.
        var questions: [(id: String, label: String, hint: String)] {
            switch self {
            case .bug: [
                ("what-happens", "What happens", "What you see, including any error text."),
                ("steps", "Steps to reproduce", "The shortest sequence that shows the problem."),
                ("expected", "Expected", "What should happen instead, and the section of the user guide that describes it, if there is one.")
            ]
            case .idea: [
                ("problem", "Problem", "What you are trying to do, and what gets in the way."),
                ("proposal", "Proposal", "What StableBar could do, or what the documentation should say.")
            ]
            }
        }
    }

    var kind = Kind.bug
    var title = ""
    /// What the user wrote, by the form field's id.
    var answers: [String: String] = [:]
    var report: BugReport?
    var crash: CrashReport?

    /// The title and the questions still empty, which the form requires before it posts.
    var missing: [String] {
        (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ["Title"] : [])
            + kind.questions.filter { answers[$0.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.label)
    }

    func fields(listLimit: Int = .max, lineLimit: Int = .max, frameLimit: Int = 60,
                messageLimit: Int = 2000) -> [(id: String, label: String, value: String)] {
        var fields = kind.questions.map { ($0.id, $0.label, answers[$0.id, default: ""]) }
        guard kind == .bug else { return fields }
        if let report { fields.append(("environment", "Environment", report.markdown(listLimit: listLimit, lineLimit: lineLimit))) }
        if let crash {
            fields.append(("evidence", "Evidence", crash.markdown(frameLimit: frameLimit, messageLimit: messageLimit, symbolLimit: 300)))
        }
        return fields
    }

    /// The issue's text as the form writes it: each field under its label.
    var body: String {
        fields().map { "### \($0.label)\n\n\($0.value.isEmpty ? "_No response_" : $0.value)" }.joined(separator: "\n\n")
    }

    var markdown: String { "# \(title)\n\n\(body)" }

    /// GitHub's issue form for this kind, filled in. Nothing is sent until the user submits the form. The crash, then
    /// the report, are cut until the address fits in `limit` characters.
    func issueURL(limit: Int = 8000) -> URL {
        func url(_ lists: Int, _ lines: Int, _ frames: Int, _ message: Int) -> URL {
            let values = [("template", kind.template), ("title", title)]
                + fields(listLimit: lists, lineLimit: lines, frameLimit: frames, messageLimit: message).map { ($0.id, $0.value) }
            let query = values.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: Self.unreserved)!)" }.joined(separator: "&")
            return URL(string: "https://github.com/Seb-GRAF/StableBar/issues/new?\(query)")!
        }
        var lists = 20, lines = 300, frames = 60, message = 2000
        var result = url(lists, lines, frames, message)
        while result.absoluteString.count > limit, frames > 0 || lists > 0 {
            if message > 200 { message /= 2 } else if frames > 0 { frames = frames * 2 / 3 } else if lines > 100 { lines /= 2 } else { lists /= 2 }
            result = url(lists, lines, frames, message)
        }
        return result
    }

    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    func post() async throws -> URL {
        guard let gh = Self.gitHubCLI() else { throw CommandFailure(message: "The GitHub CLI was not found.") }
        let output = try await runCommand(gh.path, arguments: ["issue", "create", "--repo", "github.com/Seb-GRAF/StableBar",
                                                               "--title=\(title)", "--body=\(body)"], timeout: 60)
        guard let url = URL(string: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CommandFailure(message: "The GitHub CLI didn't give the new issue's address.")
        }
        return url
    }

    /// The account the GitHub CLI on the login shell's PATH is signed in to on github.com, or nil when `gh` is missing,
    /// signed out or failed.
    static func gitHubAccount() async -> String? {
        guard let gh = gitHubCLI(),
              let output = try? await runCommand(gh.path, arguments: ["api", "--hostname", "github.com", "user", "--jq", ".login"])
        else { return nil }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func gitHubCLI() -> URL? {
        executableFile(named: "gh", path: shellEnvironment.withLock { $0["PATH", default: ""] })
    }

    /// The five open or closed issues that best match any of the title's longer words, from GitHub's search, which
    /// needs no sign-in. Only the search goes to GitHub.
    func similarIssues() async throws -> [FoundIssue] {
        let words = title.split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 3 }.prefix(6)
        var components = URLComponents(string: "https://api.github.com/search/issues")!
        components.queryItems = [URLQueryItem(name: "q", value: "repo:Seb-GRAF/StableBar is:issue " + words.joined(separator: " OR ")),
                                 URLQueryItem(name: "per_page", value: "5")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        if let response = response as? HTTPURLResponse, response.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        struct Reply: Decodable { let items: [FoundIssue] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Reply.self, from: data).items
    }
}

struct FoundIssue: Decodable, Identifiable {
    let number: Int
    let title: String
    let state: String
    let htmlUrl: URL

    var id: Int { number }
}
