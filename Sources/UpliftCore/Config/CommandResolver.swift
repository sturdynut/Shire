import Foundation

public struct CommandResolution: Equatable, Sendable {
    /// What the config said, e.g. `pnpm`.
    public var command: String
    /// The absolute path it resolved to, or nil when it couldn't be found.
    public var path: String?
    /// The version manager the path belongs to (`nvm`, `fnm`, …), if any. Such paths move when you switch versions.
    public var versionManager: String?

    public init(command: String, path: String?, versionManager: String? = nil) {
        self.command = command
        self.path = path
        self.versionManager = versionManager ?? path.flatMap(CommandResolver.versionManager(forPath:))
    }
}

public struct ResolvedEnvironment: Equatable, Sendable {
    public var commands: [String: CommandResolution]
    /// PATH from the user's login shell, for diagnostics. Services get a narrower PATH; see `servicePath`.
    public var loginPath: String

    public init(commands: [String: CommandResolution], loginPath: String) {
        self.commands = commands
        self.loginPath = loginPath
    }
}

public enum ResolveError: Error, CustomStringConvertible {
    case shellFailed(String)

    public var description: String {
        switch self {
        case .shellFailed(let detail): return "Couldn’t ask your login shell where commands live: \(detail)"
        }
    }
}

/// Finds commands the way your terminal does, because launchd won't:
/// it starts services with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and knows nothing about nvm or Homebrew.
public struct CommandResolver: Sendable {
    public var shell: String
    public var home: String
    public var runner: CommandRunning
    public var fileExists: @Sendable (String) -> Bool

    public static let launchdDefaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public init(
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        runner: CommandRunning = SystemCommandRunner(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.shell = shell
        self.home = home
        self.runner = runner
        self.fileExists = fileExists
    }

    public func resolve(_ commands: [String]) throws -> ResolvedEnvironment {
        var results: [String: CommandResolution] = [:]
        var lookups: [String] = []
        for command in Set(commands) {
            if command.contains("/") {
                let path = PathExpander.expand(command, home: home)
                results[command] = CommandResolution(command: command, path: fileExists(path) ? path : nil)
            } else {
                lookups.append(command)
            }
        }

        let output = try askLoginShell(for: lookups.sorted())
        for command in lookups {
            let found = output.commands[command].flatMap { $0.isEmpty ? nil : $0 }
            results[command] = CommandResolution(command: command, path: found)
        }
        return ResolvedEnvironment(commands: results, loginPath: output.path)
    }

    struct ShellAnswer {
        var commands: [String: String]
        var path: String
    }

    /// Runs one interactive login shell so `.zprofile` and `.zshrc` (where nvm lives) are loaded,
    /// and reads answers from marker lines so anything the rc files print is ignored.
    func askLoginShell(for commands: [String]) throws -> ShellAnswer {
        let isZsh = shell.hasSuffix("zsh")
        let lookup = isZsh ? "whence -p" : "type -P"
        var script = ""
        for command in commands where Self.isSafeCommandName(command) {
            script += "printf '__UPLIFT__%s=%s\\n' '\(command)' \"$(\(lookup) '\(command)' 2>/dev/null)\"; "
        }
        script += "printf '__UPLIFT_PATH__=%s\\n' \"$PATH\""
        let result = try runner.run(shell, ["-ilc", script], environment: nil, timeout: 20)
        if result.timedOut {
            throw ResolveError.shellFailed("\(shell) didn’t finish within 20 seconds")
        }
        return Self.parse(result.stdout)
    }

    static func parse(_ output: String) -> ShellAnswer {
        var commands: [String: String] = [:]
        var path = launchdDefaultPath
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("__UPLIFT_PATH__=") {
                path = String(line.dropFirst("__UPLIFT_PATH__=".count))
            } else if line.hasPrefix("__UPLIFT__"), let eq = line.firstIndex(of: "=") {
                let name = String(line[line.index(line.startIndex, offsetBy: "__UPLIFT__".count)..<eq])
                commands[name] = String(line[line.index(after: eq)...])
            }
        }
        return ShellAnswer(commands: commands, path: path)
    }

    static func isSafeCommandName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || "-_.+@".contains($0) }
    }

    public static func versionManager(forPath path: String) -> String? {
        let markers: [(String, String)] = [
            ("/.nvm/versions/", "nvm"),
            ("/fnm/node-versions/", "fnm"),
            ("/.fnm/", "fnm"),
            ("/.asdf/installs/", "asdf"),
            ("/mise/installs/", "mise"),
            ("/.rbenv/versions/", "rbenv"),
            ("/.pyenv/versions/", "pyenv"),
        ]
        return markers.first { path.contains($0.0) }?.1
    }

    /// Folders every service can rely on, whatever the login shell says.
    public static let stableDirectories = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]

    /// PATH for a service: its command's folder first (so `pnpm` finds the `node` beside it), then any PATH the
    /// config sets, then Homebrew and the system. Deliberately not the whole login PATH: that changes whenever
    /// you switch Node versions, and every service using it would restart for nothing.
    public static func servicePath(for resolutions: [CommandResolution], custom: String? = nil) -> String {
        var seen = Set<String>()
        var parts: [String] = []
        let commandDirs = resolutions.compactMap { $0.path }.map { ($0 as NSString).deletingLastPathComponent }
        let customDirs = (custom ?? "").split(separator: ":").map(String.init)
        let systemDirs = launchdDefaultPath.split(separator: ":").map(String.init)
        for dir in commandDirs + customDirs + stableDirectories + systemDirs {
            if !dir.isEmpty, seen.insert(dir).inserted { parts.append(dir) }
        }
        return parts.joined(separator: ":")
    }
}
