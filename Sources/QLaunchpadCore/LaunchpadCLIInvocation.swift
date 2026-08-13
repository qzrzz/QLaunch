import Foundation

/// Argv parsing and fail-closed domain resolution shared by the CLI and tests.
public enum LaunchpadCLIInvocation {
    public static let commandNames: Set<String> = ["export", "import", "validate"]
    public static let helpNames: Set<String> = ["help", "-h", "--help"]

    public static let releaseDomain = LaunchpadPreferenceStore.releaseDomain
    public static let developmentDomain = LaunchpadPreferenceStore.developmentDomain

    public static func isInvocation(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        if commandNames.contains(first) || helpNames.contains(first) {
            return true
        }
        return args.contains("--cli")
    }

    public struct Options: Equatable, Sendable {
        public var out: String?
        public var input: String?
        public var pretty = false
        public var compact = false
        public var includeCatalog = true
        public var includePaths = true
        public var domain: String?
        public var app: String?
        public var dev = false
        public var merge = false
        public var replace = false
        public var strict = false
        public var dryRun = false
        public var help = false

        public init() {}
    }

    public enum ParseError: Error, Equatable {
        case usage(String)

        public var message: String {
            switch self {
            case .usage(let text):
                return text
            }
        }
    }

    public static func parse(_ rawArgs: [String]) throws -> (command: String, options: Options) {
        let args = rawArgs.filter { $0 != "--cli" }
        guard let command = args.first else {
            throw ParseError.usage("missing command")
        }
        if helpNames.contains(command) {
            var options = Options()
            options.help = true
            return (command, options)
        }
        guard commandNames.contains(command) else {
            throw ParseError.usage("unknown command '\(command)'")
        }
        let options = try parseOptions(Array(args.dropFirst()), command: command)
        return (command, options)
    }

    public static func resolveDomain(
        explicitDomain: String?,
        appIdentifier: String?,
        dev: Bool,
        bundledIdentifier: String?
    ) throws -> String {
        if let domain = explicitDomain?.trimmingCharacters(in: .whitespacesAndNewlines),
           !domain.isEmpty {
            return domain
        }
        if let appIdentifier {
            let trimmed = appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if dev {
            return developmentDomain
        }
        if let bundledIdentifier, isPackagedDomain(bundledIdentifier) {
            return bundledIdentifier
        }
        throw ParseError.usage(
            "preference domain is required when not running from a packaged QLaunch.app / QLaunch Dev.app; use --domain, --dev, or --app"
        )
    }

    public static func isPackagedDomain(_ identifier: String) -> Bool {
        identifier == releaseDomain || identifier == developmentDomain
    }

    public static func shouldPretty(
        pretty: Bool,
        compact: Bool,
        writingToStdout: Bool,
        stdoutIsTTY: Bool
    ) throws -> Bool {
        if pretty && compact {
            throw ParseError.usage("--pretty and --compact are mutually exclusive")
        }
        if pretty { return true }
        if compact { return false }
        if writingToStdout {
            return stdoutIsTTY
        }
        return true
    }

    private static func parseOptions(_ args: [String], command: String) throws -> Options {
        var options = Options()
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-h" || arg == "--help" {
                options.help = true
                index += 1
                continue
            }
            switch arg {
            case "--out":
                options.out = try takeValue(arg, args: args, index: &index)
            case "--in":
                options.input = try takeValue(arg, args: args, index: &index)
            case "--domain":
                options.domain = try takeValue(arg, args: args, index: &index)
            case "--app":
                options.app = try takeValue(arg, args: args, index: &index)
            case "--pretty":
                options.pretty = true
                index += 1
            case "--compact":
                options.compact = true
                index += 1
            case "--no-catalog":
                options.includeCatalog = false
                index += 1
            case "--no-paths":
                options.includePaths = false
                index += 1
            case "--dev":
                options.dev = true
                index += 1
            case "--merge":
                options.merge = true
                index += 1
            case "--replace":
                options.replace = true
                index += 1
            case "--strict":
                options.strict = true
                index += 1
            case "--dry-run":
                options.dryRun = true
                index += 1
            default:
                if arg.hasPrefix("--out=") {
                    options.out = String(arg.dropFirst("--out=".count))
                    index += 1
                } else if arg.hasPrefix("--in=") {
                    options.input = String(arg.dropFirst("--in=".count))
                    index += 1
                } else if arg.hasPrefix("--domain=") {
                    options.domain = String(arg.dropFirst("--domain=".count))
                    index += 1
                } else if arg.hasPrefix("--app=") {
                    options.app = String(arg.dropFirst("--app=".count))
                    index += 1
                } else {
                    throw ParseError.usage("unexpected argument '\(arg)'")
                }
            }
        }

        switch command {
        case "export":
            if options.input != nil || options.merge || options.replace || options.strict || options.dryRun {
                throw ParseError.usage("export does not accept --in / --merge / --replace / --strict / --dry-run")
            }
        case "import":
            if options.out != nil || options.pretty || options.compact
                || !options.includeCatalog || !options.includePaths {
                throw ParseError.usage("import does not accept --out / --pretty / --compact / --no-catalog / --no-paths")
            }
        case "validate":
            if options.out != nil || options.pretty || options.compact
                || !options.includeCatalog || !options.includePaths
                || options.domain != nil || options.app != nil || options.dev
                || options.merge || options.replace || options.strict || options.dryRun {
                throw ParseError.usage("validate only accepts --in")
            }
        default:
            break
        }

        if options.pretty && options.compact {
            throw ParseError.usage("--pretty and --compact are mutually exclusive")
        }
        if options.merge && options.replace {
            throw ParseError.usage("--merge and --replace are mutually exclusive")
        }
        return options
    }

    private static func takeValue(_ flag: String, args: [String], index: inout Int) throws -> String {
        let next = index + 1
        guard next < args.count else {
            throw ParseError.usage("\(flag) requires a value")
        }
        let value = args[next]
        if value.hasPrefix("--") && value != "-" {
            throw ParseError.usage("\(flag) requires a value")
        }
        index = next + 1
        return value
    }
}
