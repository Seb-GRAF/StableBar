import Foundation

enum LaunchCommand {
    case run(URL)
    case trigger(String, [String: String])
    case reload
    case validate(URL)
    case control(URL, RuntimeRequest)
    case packages(URL, String, URL?)
    case installFromStore(URL, String)
    case renderDocsImages(URL)
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
           StableBar [--config PATH] --packages | --inspect-package PATH | --install-package PATH|ID
           StableBar [--config PATH] --enable-package ID VERSION [--persist]
           StableBar [--config PATH] --uninstall-package ID VERSION
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
                ? .packages(url, "install", source) : .installFromStore(url, arguments[1])
        case "--enable-package" where arguments.count == 3:
            self = batch([ConfigurationEdit(action: .package, properties: ["id": .string(arguments[1]), "version": .string(arguments[2]), "enabled": .bool(true)])])
        case "--uninstall-package" where arguments.count == 3:
            self = .control(url, RuntimeRequest(action: .uninstallPackage, id: arguments[1], version: arguments[2]))
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
}
