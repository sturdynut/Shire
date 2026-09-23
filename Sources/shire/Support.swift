import ArgumentParser
import Foundation
import ShireCore

struct ConfigOption: ParsableArguments {
    @Option(name: .long, help: "Config file (default: ~/.config/shire/config.yaml, or $SHIRE_CONFIG).")
    var config: String?

    var paths: ShirePaths { ShirePaths.current(configOverride: config) }

    func load() throws -> (ShirePaths, ShireConfig) {
        let paths = self.paths
        do {
            return (paths, try ConfigLoader.load(from: paths.configFile))
        } catch let error as ConfigError {
            throw ShireError(error.description)
        }
    }
}

enum Terminal {
    static let useColor: Bool = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    static func paint(_ text: String, _ code: String) -> String {
        useColor ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func green(_ text: String) -> String { paint(text, "32") }
    static func amber(_ text: String) -> String { paint(text, "33") }
    static func red(_ text: String) -> String { paint(text, "31") }
    static func dim(_ text: String) -> String { paint(text, "2") }
    static func bold(_ text: String) -> String { paint(text, "1") }

    static func error(_ text: String) -> String { red("error: ") + text }

    /// Pads by visible width so colored cells still line up.
    static func pad(_ text: String, _ width: Int) -> String {
        let visible = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count
        return text + String(repeating: " ", count: max(0, width - visible))
    }

    static func printIssues(_ issues: [ValidationIssue]) {
        for issue in issues {
            let tag = issue.severity == .error ? red("error") : amber("warning")
            print("\(tag)  \(issue)")
        }
    }
}

/// The path launchd should run for `shire run`: this binary, with symlinks resolved.
func currentExecutablePath() -> String {
    let url = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    return url.resolvingSymlinksInPath().path
}

/// Resolves every managed command through the login shell and fails with a readable message if that's impossible.
func resolveCommands(_ config: ShireConfig) throws -> ResolvedEnvironment {
    let commands = config.services.values.compactMap { $0.isExternal ? nil : $0.command }
    do {
        return try CommandResolver().resolve(commands)
    } catch {
        throw ShireError(String(describing: error))
    }
}

/// A failure explained in plain words. ArgumentParser prints it after “Error:” and exits with status 1.
struct ShireError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

struct ValidationFailed: Error, CustomStringConvertible {
    var description: String { "Fix the errors above, then run the command again." }
}
