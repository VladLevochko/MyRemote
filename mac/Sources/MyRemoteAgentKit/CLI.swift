import Foundation
import MyRemoteCore

public enum CLIError: Error, Equatable, CustomStringConvertible {
    case unknownArgument(String)
    case missingValue(String)
    case invalidValue(flag: String, value: String)

    public var description: String {
        switch self {
        case let .unknownArgument(argument): return "unknown argument: \(argument)"
        case let .missingValue(flag): return "\(flag) needs a value"
        case let .invalidValue(flag, value): return "invalid value for \(flag): \(value)"
        }
    }
}

public enum CLICommand: Equatable {
    case run(AgentOptions)
    case help
}

/// PROTOCOL.md section 6:
///
///     MyRemoteAgent --headless [--dry-run] [--loopback] [--port <n>] [--state-dir <path>]
public enum CLI {
    public static let usage = """
    Usage: MyRemoteAgent [--headless] [--dry-run] [--loopback] [--port <n>] [--state-dir <path>]

      --headless          No menu bar UI, only the server.
      --dry-run           Do not inject events; print each action as "INJECT <json>" on stdout.
      --loopback          Use host=127.0.0.1 in the pairing URI (the server still listens on all interfaces).
      --port <n>          Port to listen on (default 47110; 0 = any free port). Falls back to a free port if busy.
      --state-dir <path>  Where the certificate, token and agent id live
                          (default ~/Library/Application Support/MyRemote).

    Extensions outside the protocol contract:
      --profile <name>    Pin the profile (youtube|netflix|appletv|generic) instead of following the front app.
      --no-bonjour        Do not advertise _myremote._tcp.
      --help              Show this text.

    After the server has started, "PAIRING <pairing-uri>" is printed on stdout.
    """

    /// - Parameter arguments: without the program name.
    public static func parse(_ arguments: [String]) throws -> CLICommand {
        var options = AgentOptions()
        var index = 0

        /// Supports both `--flag value` and `--flag=value`.
        func value(for flag: String, inline: String?) throws -> String {
            if let inline { return inline }
            index += 1
            guard index < arguments.count else { throw CLIError.missingValue(flag) }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            let flag: String
            let inline: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                flag = String(argument[argument.startIndex..<equals])
                inline = String(argument[argument.index(after: equals)...])
            } else {
                flag = argument
                inline = nil
            }

            switch flag {
            case "--headless":
                options.headless = true
            case "--dry-run":
                options.dryRun = true
            case "--loopback":
                options.loopback = true
            case "--no-bonjour":
                options.advertise = false
            case "--port":
                let text = try value(for: flag, inline: inline)
                guard let port = UInt16(text) else { throw CLIError.invalidValue(flag: flag, value: text) }
                options.port = port
            case "--state-dir":
                let text = try value(for: flag, inline: inline)
                guard !text.isEmpty else { throw CLIError.invalidValue(flag: flag, value: text) }
                options.stateDirectory = URL(
                    fileURLWithPath: (text as NSString).expandingTildeInPath, isDirectory: true)
            case "--profile":
                let text = try value(for: flag, inline: inline)
                guard let profile = Profile(rawValue: text) else {
                    throw CLIError.invalidValue(flag: flag, value: text)
                }
                options.forcedProfile = profile
            case "--help", "-h":
                return .help
            default:
                // Launch Services may pass a process serial number to app bundles.
                if argument.hasPrefix("-psn_") { break }
                throw CLIError.unknownArgument(argument)
            }
            index += 1
        }
        return .run(options)
    }
}
