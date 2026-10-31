import Foundation

enum LaunchCommand {
    case run(URL)
    case trigger(String, [String: String])
    case reload
    case validate(URL)
    case control(URL, RuntimeRequest)
    case packages(URL, String, URL?)
    case installFromStore(URL, String, String?)
    case buildSource(packages: URL, output: URL, previous: URL?, url: URL?, name: String?)
    case renderDocsImages(URL)
    case renderScenes(output: URL, scenes: [URL])
    case triage(URL, agent: TriageAgent?, model: String?)
    case triageContext(URL)
    case report(URL)
    case uninstall(removesConfiguration: Bool, showsMenuBar: Bool, confirmed: Bool)
    case help

    static let configurationURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/stablebar/config.json")
    static let reloadNotification = Notification.Name("com.stablebar.reload")
    static let usage = """
    Usage: StableBar [--config PATH]
           StableBar --validate [PATH]
           StableBar --trigger EVENT [KEY=VALUE ...]
           StableBar --reload
           StableBar [--config PATH] --customize
           StableBar [--config PATH] --query [ID]
           StableBar [--config PATH] --set ID JSON [--persist]
           StableBar [--config PATH] --add JSON | --remove ID | --reorder ID... [--persist]
           StableBar [--config PATH] --batch JSON_ARRAY [--persist]
           StableBar [--config PATH] --profile NAME|auto [--persist]
           StableBar [--config PATH] --reset | --refresh ID | --popup ID
           StableBar [--config PATH] --packages | --inspect-package PATH | --install-package PATH|ID [--source SOURCE]
           StableBar --build-source PACKAGES OUT [--previous FILE] [--url URL --name NAME]
           StableBar [--config PATH] --enable-package ID VERSION [--persist]
           StableBar [--config PATH] --uninstall-package ID VERSION
           StableBar [--config PATH] triage [--agent claude|codex] [--model MODEL]
           StableBar [--config PATH] --report
           StableBar --uninstall [--remove-config] [--show-menu-bar] [--yes]
           StableBar --help
    """

    init(arguments: [String]) throws {
        var arguments = arguments
        var url = Self.configurationURL
        let targeted = arguments.first == "--config"
        if arguments.first == "--config" {
            guard arguments.count >= 2 else { throw CommandFailure(message: Self.usage) }
            url = URL(filePath: (arguments[1] as NSString).expandingTildeInPath)
            arguments.removeFirst(2)
        }
        let persist = arguments.last == "--persist"
        if persist { arguments.removeLast() }
        func object(_ text: String) throws -> [String: ConfigurationValue] {
            try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(text.utf8))
        }
        func batch(_ edits: [ConfigurationEdit]) -> LaunchCommand {
            .control(url, RuntimeRequest(action: .batch, edits: edits, persist: persist))
        }
        switch arguments.first {
        case nil:
            self = .run(url)
        case "--customize" where arguments.count == 1:
            self = .control(url, RuntimeRequest(action: .customize))
        case "--query" where arguments.count <= 2:
            self = .control(url, RuntimeRequest(action: .query, id: arguments.count == 2 ? arguments[1] : nil))
        case "--set" where arguments.count == 3:
            self = batch([ConfigurationEdit(action: .set, id: arguments[1], properties: try object(arguments[2]))])
        case "--add" where arguments.count == 2:
            self = batch([ConfigurationEdit(action: .add, properties: try object(arguments[1]))])
        case "--remove" where arguments.count == 2:
            self = batch([ConfigurationEdit(action: .remove, id: arguments[1])])
        case "--reorder" where arguments.count >= 2:
            self = batch([ConfigurationEdit(action: .reorder, ids: Array(arguments.dropFirst()))])
        case "--batch" where arguments.count == 2:
            self = batch(try JSONDecoder().decode([ConfigurationEdit].self, from: Data(arguments[1].utf8)))
        case "--profile" where arguments.count == 2:
            self = batch([ConfigurationEdit(action: .profile, name: arguments[1] == "auto" ? nil : arguments[1])])
        case "--reset" where arguments.count == 1:
            self = .control(url, RuntimeRequest(action: .reset))
        case "--refresh" where arguments.count == 2:
            self = .control(url, RuntimeRequest(action: .refresh, id: arguments[1]))
        case "--popup" where arguments.count == 2:
            self = .control(url, RuntimeRequest(action: .popup, id: arguments[1]))
        case "--packages" where arguments.count == 1:
            self = .packages(url, "list", nil)
        case "--inspect-package" where arguments.count == 2:
            self = .packages(url, "inspect", URL(filePath: (arguments[1] as NSString).expandingTildeInPath))
        case "--install-package" where arguments.count == 2:
            let source = URL(filePath: (arguments[1] as NSString).expandingTildeInPath)
            self = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                ? .packages(url, "install", source) : .installFromStore(url, arguments[1], nil)
        case "--install-package" where arguments.count == 4 && arguments[2] == "--source":
            self = .installFromStore(url, arguments[1], arguments[3])
        case "--enable-package" where arguments.count == 3:
            self = batch([ConfigurationEdit(action: .package, properties: ["id": .string(arguments[1]), "version": .string(arguments[2]), "enabled": .bool(true)])])
        case "--uninstall-package" where arguments.count == 3:
            self = .control(url, RuntimeRequest(action: .uninstallPackage, id: arguments[1], version: arguments[2]))
        case "--build-source" where arguments.count >= 3:
            self = try Self.buildSource(Array(arguments.dropFirst()))
        case "--validate" where arguments.count <= 2:
            let url = arguments.count == 2 ? URL(filePath: (arguments[1] as NSString).expandingTildeInPath) : url
            self = .validate(url)
        case "--trigger" where arguments.count >= 2:
            guard !arguments[1].isEmpty else { throw CommandFailure(message: "An event name is required.") }
            var environment: [String: String] = [:]
            for argument in arguments.dropFirst(2) {
                let pair = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, pair[0].range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
                    throw CommandFailure(message: "Event data must use KEY=VALUE: \(argument)")
                }
                environment[String(pair[0])] = String(pair[1])
            }
            self = targeted ? .control(url, RuntimeRequest(action: .trigger, id: arguments[1], environment: environment))
                : .trigger(arguments[1], environment)
        case "--reload" where arguments.count == 1:
            self = targeted ? .control(url, RuntimeRequest(action: .reload)) : .reload
        case "--render-docs-images" where arguments.count == 2:
            self = .renderDocsImages(URL(filePath: (arguments[1] as NSString).expandingTildeInPath))
        case "--render-scenes" where arguments.count >= 3:
            let paths = arguments.dropFirst().map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
            self = .renderScenes(output: paths[0], scenes: Array(paths.dropFirst()))
        case "triage":
            self = try Self.triage(url, Array(arguments.dropFirst()))
        case "--triage-context" where arguments.count == 1:
            self = .triageContext(url)
        case "--report" where arguments.count == 1 && !persist:
            self = .report(url)
        case "--uninstall" where targeted:
            throw CommandFailure(message: "--uninstall removes StableBar for every configuration, so it doesn't take --config.")
        case "--uninstall":
            let options = Array(arguments.dropFirst())
            guard Set(options).count == options.count, options.allSatisfy(["--remove-config", "--show-menu-bar", "--yes"].contains) else {
                throw CommandFailure(message: Self.usage)
            }
            self = .uninstall(removesConfiguration: options.contains("--remove-config"), showsMenuBar: options.contains("--show-menu-bar"),
                              confirmed: options.contains("--yes"))
        case "--help" where arguments.count == 1:
            self = .help
        default:
            throw CommandFailure(message: Self.usage)
        }
        if persist {
            guard case let .control(_, request) = self, request.action == .batch else {
                throw CommandFailure(message: "--persist requires a configuration edit.")
            }
        }
    }

    /// `--agent` and `--model`, each at most once, in any order.
    private static func triage(_ url: URL, _ arguments: [String]) throws -> LaunchCommand {
        var options: [String: String] = [:]
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            guard ["--agent", "--model"].contains(flag), options[flag] == nil, let value = rest.popFirst() else {
                throw CommandFailure(message: Self.usage)
            }
            options[flag] = value
        }
        let agent = try options["--agent"].map { name in
            guard let agent = TriageAgent(rawValue: name) else { throw CommandFailure(message: "--agent takes claude or codex.") }
            return agent
        }
        return .triage(url, agent: agent, model: options["--model"])
    }

    /// `PACKAGES OUT`, then `--previous FILE`, `--url URL` and `--name NAME` in any order. A join link needs both `--url` and `--name`.
    private static func buildSource(_ arguments: [String]) throws -> LaunchCommand {
        func path(_ text: String) -> URL { URL(filePath: (text as NSString).expandingTildeInPath) }
        var options: [String: String] = [:]
        var rest = arguments.dropFirst(2)
        while let flag = rest.popFirst() {
            guard ["--previous", "--url", "--name"].contains(flag), options[flag] == nil, let value = rest.popFirst() else {
                throw CommandFailure(message: Self.usage)
            }
            options[flag] = value
        }
        guard (options["--url"] == nil) == (options["--name"] == nil) else {
            throw CommandFailure(message: "--url and --name go together: the join link needs both.")
        }
        var url: URL?
        if let text = options["--url"], let name = options["--name"] {
            guard let parsed = URL(string: text) else { throw CommandFailure(message: "--url isn’t a URL.") }
            do {
                _ = try PackageSource.validated(id: "source", name: name, url: parsed)
            } catch PackageSourceError.emptyName {
                throw CommandFailure(message: "--name can’t be empty.")
            } catch PackageSourceError.insecureURL {
                throw CommandFailure(message: "--url needs an https URL.")
            } catch PackageSourceError.queryInURL {
                throw CommandFailure(message: "--url needs an index URL without ?query or #fragment.")
            } catch PackageSourceError.credentialsInURL {
                throw CommandFailure(message: "--url needs an index URL without a user name or password.")
            }
            url = parsed
        }
        return .buildSource(packages: path(arguments[0]), output: path(arguments[1]), previous: options["--previous"].map(path),
                            url: url, name: options["--name"]?.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
