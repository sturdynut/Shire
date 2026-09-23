import Foundation

public enum ProcessState: Equatable, Sendable {
    case running(pid: Int, since: Date?)
    case crashLooping(lastExit: Int32, exits: Int, window: DurationValue)
    case exited(code: Int32)
    case stopped
    case notInstalled
    case external(running: Bool, pid: Int?)
    case externalMissing(label: String)

    public var label: String {
        switch self {
        case .running: return "running"
        case .crashLooping: return "crash-looping"
        case .exited(let code): return code == 0 ? "exited" : "exited \(code)"
        case .stopped: return "stopped"
        case .notInstalled: return "not applied"
        case .external(let running, _): return running ? "external" : "external, stopped"
        case .externalMissing: return "external, not found"
        }
    }

    public var isProblem: Bool {
        switch self {
        case .running, .external(true, _): return false
        default: return true
        }
    }
}

public struct ServiceStatus: Equatable, Sendable {
    public var name: String
    public var process: ProcessState
    public var health: HealthResult?
    /// A plain-language reason, when Shire recognises what went wrong.
    public var cause: String?

    public init(name: String, process: ProcessState, health: HealthResult? = nil, cause: String? = nil) {
        self.name = name
        self.process = process
        self.health = health
        self.cause = cause
    }
}

/// Works out process state from launchd and the event log, then names the likely cause from a fixed list of patterns.
public struct StatusInspector: Sendable {
    public var paths: ShirePaths
    public var launchControl: LaunchControl
    public var crashLoop: CrashLoopRule
    public var fileExists: @Sendable (String) -> Bool
    public var directoryExists: @Sendable (String) -> Bool

    public init(paths: ShirePaths, launchControl: LaunchControl, crashLoop: CrashLoopRule,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                directoryExists: @escaping @Sendable (String) -> Bool = { path in
                    var isDir: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                }) {
        self.paths = paths
        self.launchControl = launchControl
        self.crashLoop = crashLoop
        self.fileExists = fileExists
        self.directoryExists = directoryExists
    }

    public func processState(name: String, service: ServiceConfig, now: Date = Date()) -> ProcessState {
        if let external = service.external {
            guard let info = launchControl.info(external) else { return .externalMissing(label: external) }
            return .external(running: info.isRunning, pid: info.pid)
        }
        let label = LaunchAgentBuilder.label(for: name)
        guard let info = launchControl.info(label) else {
            return fileExists(paths.plist(forLabel: label).path) ? .stopped : .notInstalled
        }
        let events = EventLog(url: paths.events(for: name)).read()
        if let loop = Self.crashLoop(in: events, rule: crashLoop, now: now) {
            return loop
        }
        if info.isRunning, let pid = info.pid {
            let since = events.last(where: { $0.kind == .start })?.time
            return .running(pid: pid, since: since)
        }
        if let code = info.lastExitCode { return .exited(code: Int32(code)) }
        return .stopped
    }

    /// Crash-looping means at least `rule.count` failed exits inside the window, the latest one recently
    /// enough that the service hasn't since stayed up.
    public static func crashLoop(in events: [ServiceEvent], rule: CrashLoopRule, now: Date) -> ProcessState? {
        let windowStart = now.addingTimeInterval(-rule.window.seconds)
        let failures = events.filter { $0.kind == .exit && ($0.code ?? 0) != 0 && $0.time >= windowStart }
        guard failures.count >= rule.count, let last = failures.last else { return nil }
        if let lastStart = events.last(where: { $0.kind == .start }), lastStart.time > last.time,
           now.timeIntervalSince(lastStart.time) > 60 {
            return nil // It started again after the last failure and has stayed up for a minute.
        }
        return .crashLooping(lastExit: last.code ?? 0, exits: failures.count, window: rule.window)
    }

    /// The fixed list of patterns from the plan. Returns nil when nothing matches; guessing is worse than silence.
    public func likelyCause(name: String, service: ServiceConfig, state: ProcessState, dependencyHealth: [String: HealthResult]) -> String? {
        for dependency in service.dependsOn {
            if let health = dependencyHealth[dependency], !health.isHealthy, state.isProblem {
                return "\(dependency) isn’t reachable (\(health.detail)), so \(name) is waiting for it."
            }
        }
        if let cwd = service.cwd {
            let path = PathExpander.expand(cwd, home: paths.home.path)
            if !directoryExists(path) { return "working folder \(path) is missing." }
        }

        let exitCode: Int32?
        switch state {
        case .crashLooping(let code, _, _): exitCode = code
        case .exited(let code): exitCode = code
        default: exitCode = nil
        }
        guard let exitCode else { return nil }

        if exitCode == ServiceRunner.exitCommandNotFound {
            let command = installedCommand(for: name)
            if let command, !fileExists(command) {
                if let manager = CommandResolver.versionManager(forPath: command) {
                    let tool = (command as NSString).lastPathComponent
                    return "\(tool) moved: \(manager) switched versions since the last apply. Run `shire apply` to re-resolve."
                }
                return "\(command) no longer exists. Run `shire apply` to re-resolve it."
            }
            return "command not found (exit 127)."
        }
        if exitCode == ServiceRunner.exitHandedOff {
            return "\(name) is already open without the options Shire starts it with (like a debug port). Quit it once; Shire will start it properly."
        }
        if exitCode == ServiceRunner.exitDependencyTimeout {
            return "gave up waiting for a dependency; launchd will retry."
        }

        let recent = LogReader.tail(paths.stderrLog(for: name), lines: 80).joined(separator: "\n")
        if recent.contains("EADDRINUSE") || recent.contains("address already in use") {
            return "its port is already in use by another process."
        }
        if exitCode == ServiceRunner.exitNotExecutable || recent.contains("EACCES") || recent.contains("Permission denied") {
            return "permission denied; check the command and files it opens."
        }
        return nil
    }

    /// The real command recorded in the installed plist (after the `--`).
    public func installedCommand(for name: String) -> String? {
        let url = paths.plist(forLabel: LaunchAgentBuilder.label(for: name))
        guard let plist = LaunchAgentBuilder.read(url), let args = plist["ProgramArguments"] as? [String],
              let dash = args.firstIndex(of: "--"), dash + 1 < args.count else { return nil }
        return args[dash + 1]
    }
}
