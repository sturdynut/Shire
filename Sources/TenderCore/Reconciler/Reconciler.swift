import Foundation

public struct PlannedChange {
    public enum Action: Equatable {
        case install
        case update(reasons: [String])
        /// Plist is current but the job isn't loaded (stopped, or never started after a reboot of launchd state).
        case start
        case unchanged
        case remove
        /// External services are only watched.
        case watch(label: String)
    }

    public var name: String
    public var action: Action
    public var plist: [String: Any]?
    public var label: String

    public init(name: String, action: Action, plist: [String: Any]?, label: String? = nil) {
        self.name = name
        self.action = action
        self.plist = plist
        self.label = label ?? LaunchAgentBuilder.label(for: name)
    }

    /// The name tender-agent appears under in plans and output.
    public static let agentName = "tender-agent"

    public var isAgent: Bool { label == LaunchAgentBuilder.agentLabel }

    public var summary: String {
        switch action {
        case .install: return "install and start"
        case .update(let reasons): return "restart (\(reasons.joined(separator: ", ")))"
        case .start: return "start"
        case .unchanged: return "unchanged"
        case .remove: return "stop and remove"
        case .watch(let label): return "watch \(label)"
        }
    }

    public var changesSomething: Bool {
        switch action {
        case .unchanged, .watch: return false
        default: return true
        }
    }
}

public struct ApplyPlan {
    public var changes: [PlannedChange]

    public var hasChanges: Bool { changes.contains { $0.changesSomething } }
}

public struct ApplyOutcome: Equatable, Sendable {
    public enum Result: Equatable, Sendable {
        case done(String)
        case skipped(String)
        case failed(String)
    }

    public var name: String
    public var result: Result
}

/// Builds a service (`build:`) before it's (re)started. A protocol so tests don't run real builds.
public protocol ServiceBuilding: Sendable {
    func build(name: String, command: String, cwd: String?, environment: [String: String]) -> Bool
}

/// Runs the build through `/bin/zsh -c` with the service's PATH and env, output straight to the terminal.
public struct ShellServiceBuilder: ServiceBuilding {
    public init() {}

    public func build(name: String, command: String, cwd: String?, environment: [String: String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.environment = environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

public struct Reconciler: Sendable {
    public var paths: TenderPaths
    public var launchControl: LaunchControl
    public var builder: ServiceBuilding

    public init(paths: TenderPaths, launchControl: LaunchControl, builder: ServiceBuilding = ShellServiceBuilder()) {
        self.paths = paths
        self.launchControl = launchControl
        self.builder = builder
    }

    // MARK: Desired state

    public func desiredPlists(config: TenderConfig, resolved: ResolvedEnvironment, tenderExecutable: String) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for name in config.managedServiceNames {
            let service = config.services[name]!
            guard let command = service.command, let resolution = resolved.commands[command], let path = resolution.path else { continue }
            let waits = service.dependsOn.compactMap { config.services[$0]?.health?.endpoint }
            let inputs = AgentInputs(
                name: name,
                service: service,
                resolvedCommand: path,
                servicePath: CommandResolver.servicePath(for: [resolution], custom: service.env["PATH"]),
                tenderExecutable: tenderExecutable,
                paths: paths,
                logs: config.logs,
                dependencyWaits: waits
            )
            result[name] = LaunchAgentBuilder.plist(inputs)
        }
        return result
    }

    /// Names of services whose LaunchAgent Tender installed earlier.
    public func installedServices() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: paths.launchAgentsDir.path)) ?? []
        return files.compactMap { file -> String? in
            guard file.hasSuffix(".plist") else { return nil }
            return LaunchAgentBuilder.serviceName(fromLabel: String(file.dropLast(".plist".count)))
        }.sorted()
    }

    // MARK: Plan

    /// `agentPlist` is tender-agent's LaunchAgent; nil leaves the agent out of the plan (tests of services alone).
    public func plan(config: TenderConfig, desired: [String: [String: Any]], agentPlist: [String: Any]? = nil) -> ApplyPlan {
        var changes: [PlannedChange] = []
        let installed = Set(installedServices())

        if let agentPlist {
            var agent = change(name: PlannedChange.agentName, label: LaunchAgentBuilder.agentLabel, desired: agentPlist)
            let executable = (agentPlist["ProgramArguments"] as? [String])?.first ?? ""
            if agent.action == .unchanged,
               Self.agentIsOutdated(agentStartedAt: AgentState.read(from: paths.agentStateFile)?.startedAt, executable: executable) {
                agent.action = .update(reasons: ["tender was updated"])
            }
            changes.append(agent)
        }

        for name in installed.subtracting(config.managedServiceNames).sorted() {
            changes.append(PlannedChange(name: name, action: .remove, plist: nil))
        }

        for name in DependencyOrder.sorted(config) {
            let service = config.services[name]!
            if let external = service.external {
                changes.append(PlannedChange(name: name, action: .watch(label: external), plist: nil))
                continue
            }
            guard let plist = desired[name] else { continue }
            changes.append(change(name: name, label: LaunchAgentBuilder.label(for: name), desired: plist))
        }
        return ApplyPlan(changes: changes)
    }

    /// True when the tender binary was replaced after the running agent started, so the agent runs old code.
    public static func agentIsOutdated(agentStartedAt: Date?, executable: String) -> Bool {
        guard let started = agentStartedAt,
              let modified = (try? FileManager.default.attributesOfItem(atPath: executable))?[.modificationDate] as? Date
        else { return false }
        return modified > started
    }

    private func change(name: String, label: String, desired plist: [String: Any]) -> PlannedChange {
        guard let current = LaunchAgentBuilder.read(paths.plist(forLabel: label)) else {
            return PlannedChange(name: name, action: .install, plist: plist, label: label)
        }
        let reasons = LaunchAgentBuilder.differences(installed: current, desired: plist)
        if !reasons.isEmpty {
            return PlannedChange(name: name, action: .update(reasons: reasons), plist: plist, label: label)
        }
        if !launchControl.isLoaded(label) {
            return PlannedChange(name: name, action: .start, plist: plist, label: label)
        }
        return PlannedChange(name: name, action: .unchanged, plist: plist, label: label)
    }

    // MARK: Apply

    public func apply(_ plan: ApplyPlan, config: TenderConfig, resolved: ResolvedEnvironment, build: Bool,
                      progress: (String) -> Void = { _ in }) -> [ApplyOutcome] {
        var outcomes: [ApplyOutcome] = []
        try? FileManager.default.createDirectory(at: paths.launchAgentsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.eventsDir, withIntermediateDirectories: true)

        for change in plan.changes {
            switch change.action {
            case .unchanged, .watch:
                continue
            case .remove:
                do {
                    try launchControl.bootout(change.label)
                    try? FileManager.default.removeItem(at: paths.plist(forLabel: change.label))
                    outcomes.append(ApplyOutcome(name: change.name, result: .done("stopped and removed")))
                } catch {
                    outcomes.append(ApplyOutcome(name: change.name, result: .failed(String(describing: error))))
                }
            case .install, .update, .start:
                outcomes.append(install(change, config: config, resolved: resolved, build: build, progress: progress))
            }
        }
        return outcomes
    }

    private func install(_ change: PlannedChange, config: TenderConfig, resolved: ResolvedEnvironment, build: Bool,
                         progress: (String) -> Void) -> ApplyOutcome {
        let service = change.isAgent ? nil : config.services[change.name]
        guard let plist = change.plist else {
            return ApplyOutcome(name: change.name, result: .failed("no LaunchAgent could be generated"))
        }

        if build, change.action != .start, let service, let command = service.build {
            progress("building \(change.name): \(command)")
            let environment = buildEnvironment(service: service, plist: plist)
            let cwd = service.cwd.map { PathExpander.expand($0, home: paths.home.path) }
            if !builder.build(name: change.name, command: command, cwd: cwd, environment: environment) {
                return ApplyOutcome(name: change.name, result: .failed("build failed (\(command)); left the running version alone"))
            }
        }

        let url = paths.plist(forLabel: change.label)
        do {
            if launchControl.isLoaded(change.label) {
                try launchControl.bootout(change.label)
            }
            try LaunchAgentBuilder.data(for: plist).write(to: url, options: .atomic)
            try launchControl.bootstrap(plist: url, label: change.label)
        } catch {
            return ApplyOutcome(name: change.name, result: .failed(String(describing: error)))
        }
        switch change.action {
        case .install: return ApplyOutcome(name: change.name, result: .done("installed and started"))
        case .start: return ApplyOutcome(name: change.name, result: .done("started"))
        default: return ApplyOutcome(name: change.name, result: .done("restarted"))
        }
    }

    /// Stops and removes every LaunchAgent Tender installed, tender-agent included. Logs and config stay.
    public func uninstall() -> [ApplyOutcome] {
        var outcomes: [ApplyOutcome] = []
        let targets = installedServices().map { ($0, LaunchAgentBuilder.label(for: $0)) }
            + [(PlannedChange.agentName, LaunchAgentBuilder.agentLabel)]
        for (name, label) in targets {
            let url = paths.plist(forLabel: label)
            let present = FileManager.default.fileExists(atPath: url.path)
            guard present || launchControl.isLoaded(label) else { continue }
            do {
                try launchControl.bootout(label)
                try? FileManager.default.removeItem(at: url)
                outcomes.append(ApplyOutcome(name: name, result: .done("stopped and removed")))
            } catch {
                outcomes.append(ApplyOutcome(name: name, result: .failed(String(describing: error))))
            }
        }
        return outcomes
    }

    /// The environment a build (or anything run on the service's behalf) should see.
    public func buildEnvironment(service: ServiceConfig, plist: [String: Any]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let fromPlist = plist["EnvironmentVariables"] as? [String: String] {
            environment.merge(fromPlist) { _, new in new }
        }
        if let envFile = service.envFile {
            let cwd = service.cwd.map { PathExpander.expand($0, home: paths.home.path) }
            let url = URL(fileURLWithPath: PathExpander.expand(envFile, home: paths.home.path, base: cwd))
            if let values = try? EnvFile.load(url) {
                environment.merge(values) { _, new in new }
            }
        }
        return environment
    }
}
