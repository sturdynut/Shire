import Foundation

/// Everything needed to write one service's LaunchAgent.
public struct AgentInputs {
    public var name: String
    public var service: ServiceConfig
    public var resolvedCommand: String
    public var servicePath: String
    public var tenderExecutable: String
    public var paths: TenderPaths
    public var logs: LogSettings
    public var dependencyWaits: [HostPort]

    public init(name: String, service: ServiceConfig, resolvedCommand: String, servicePath: String,
                tenderExecutable: String, paths: TenderPaths, logs: LogSettings, dependencyWaits: [HostPort]) {
        self.name = name
        self.service = service
        self.resolvedCommand = resolvedCommand
        self.servicePath = servicePath
        self.tenderExecutable = tenderExecutable
        self.paths = paths
        self.logs = logs
        self.dependencyWaits = dependencyWaits
    }
}

public enum LaunchAgentBuilder {
    public static let labelPrefix = "com.tender."

    public static func label(for service: String) -> String { labelPrefix + service }

    /// tender-agent's label. The service name `agent` is reserved so the two can't collide.
    public static let agentLabel = labelPrefix + reservedServiceName
    public static let reservedServiceName = "agent"

    /// The service a Tender label belongs to; nil for other labels and for tender-agent itself.
    public static func serviceName(fromLabel label: String) -> String? {
        guard label.hasPrefix(labelPrefix), label != agentLabel else { return nil }
        return String(label.dropFirst(labelPrefix.count))
    }

    /// tender-agent's own LaunchAgent: always running, restarted if it ever exits.
    public static func agentPlist(executable: String, paths: TenderPaths) -> [String: Any] {
        [
            "Label": agentLabel,
            "ProgramArguments": [executable, "agent", "--config", paths.configFile.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Background",
            "StandardOutPath": paths.agentLog.path,
            "StandardErrorPath": paths.agentLog.path,
        ]
    }

    /// The plist launchd runs. It always starts `tender run`, which owns logging, env files and dependency waits,
    /// then runs the real command. Secrets from `envFile` are read at start time and never written here.
    public static func plist(_ inputs: AgentInputs) -> [String: Any] {
        let home = inputs.paths.home.path
        let cwd = inputs.service.cwd.map { PathExpander.expand($0, home: home) }

        var runArguments = [
            inputs.tenderExecutable, "run", inputs.name,
            "--log-dir", inputs.paths.logsDir.path,
            "--max-log-size", String(inputs.logs.maxSize.bytes),
            "--keep-logs", String(inputs.logs.keep),
            "--events", inputs.paths.events(for: inputs.name).path,
        ]
        if let envFile = inputs.service.envFile {
            runArguments += ["--env-file", PathExpander.expand(envFile, home: home, base: cwd)]
        }
        for wait in inputs.dependencyWaits {
            runArguments += ["--wait-for", wait.description]
        }
        if inputs.service.adoptRunning, let endpoint = inputs.service.health?.endpoint {
            runArguments += ["--adopt", endpoint.description]
        }
        runArguments += ["--", inputs.resolvedCommand] + inputs.service.args

        var environment = inputs.service.env
        environment["PATH"] = inputs.servicePath
        environment["TENDER_SERVICE"] = inputs.name

        var plist: [String: Any] = [
            "Label": label(for: inputs.name),
            "ProgramArguments": runArguments,
            "EnvironmentVariables": environment,
            "RunAtLoad": true,
            "ThrottleInterval": 10,
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": inputs.paths.wrapperLog(for: inputs.name).path,
            "StandardErrorPath": inputs.paths.wrapperLog(for: inputs.name).path,
        ]
        if let cwd { plist["WorkingDirectory"] = cwd }
        switch inputs.service.restart {
        case .always: plist["KeepAlive"] = true
        case .onFailure: plist["KeepAlive"] = ["SuccessfulExit": false]
        case .never: plist["KeepAlive"] = false
        }
        return plist
    }

    public static func data(for plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    public static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return object as? [String: Any]
    }

    /// Plain-language reasons two plists differ, for “Apply will…”.
    public static func differences(installed: [String: Any], desired: [String: Any]) -> [String] {
        let keys = Set(installed.keys).union(desired.keys).sorted()
        var reasons: [String] = []
        for key in keys {
            let a = installed[key].map { $0 as AnyObject }
            let b = desired[key].map { $0 as AnyObject }
            if let a, let b, a.isEqual(b) { continue }
            switch key {
            case "ProgramArguments":
                reasons.append(contentsOf: programArgumentReasons(installed[key] as? [String] ?? [], desired[key] as? [String] ?? []))
            case "EnvironmentVariables":
                let before = installed[key] as? [String: String] ?? [:]
                let after = desired[key] as? [String: String] ?? [:]
                if before["PATH"] != after["PATH"] { reasons.append("PATH changed") }
                var withoutPath = (before, after)
                withoutPath.0["PATH"] = nil
                withoutPath.1["PATH"] = nil
                if withoutPath.0 != withoutPath.1 { reasons.append("environment changed") }
            case "WorkingDirectory": reasons.append("working folder changed")
            case "KeepAlive": reasons.append("restart policy changed")
            default: reasons.append("\(key) changed")
            }
        }
        return reasons
    }

    private static func programArgumentReasons(_ before: [String], _ after: [String]) -> [String] {
        func split(_ args: [String]) -> (head: [String], command: String?, rest: [String]) {
            guard let dash = args.firstIndex(of: "--") else { return (args, nil, []) }
            let tail = Array(args[(dash + 1)...])
            return (Array(args[..<dash]), tail.first, Array(tail.dropFirst()))
        }
        let a = split(before), b = split(after)
        var reasons: [String] = []
        if a.command != b.command { reasons.append("command now \(b.command ?? "missing")") }
        if a.rest != b.rest { reasons.append("arguments changed") }
        if a.head.first != b.head.first { reasons.append("tender moved to \(b.head.first ?? "?")") }
        if Array(a.head.dropFirst()) != Array(b.head.dropFirst()) { reasons.append("run options changed") }
        return reasons
    }
}
