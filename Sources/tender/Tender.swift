import ArgumentParser
import Foundation
import TenderCore

@main
struct Tender: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tender",
        abstract: "Keep a Mac in the state config.yaml describes: services running, healthy, and explained when they aren't.",
        version: "0.1.0",
        subcommands: [Apply.self, Status.self, Doctor.self, Start.self, Stop.self, Restart.self, Logs.self, Validate.self, Run.self, Agent.self, Uninstall.self, Alerts.self]
    )
}

// MARK: - apply

struct Apply: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Make the Mac match config.yaml. Only services that changed are restarted.")

    @OptionGroup var options: ConfigOption

    @Flag(name: .long, help: "Show what would change without changing anything.")
    var dryRun = false

    @Flag(name: .long, help: "Skip `build:` steps.")
    var noBuild = false

    func run() throws {
        let (paths, config) = try options.load()
        let resolved = try resolveCommands(config)
        let issues = Validator(home: paths.home.path).validate(config, resolved: resolved)
        Terminal.printIssues(issues)
        if issues.contains(where: { $0.severity == .error }) { throw ValidationFailed() }

        let executable = currentExecutablePath()
        if executable.contains("/.build/") {
            print(Terminal.amber("note") + "  LaunchAgents will point at \(executable), a build folder. Install tender (make install) before relying on it.")
        }

        let reconciler = Reconciler(paths: paths, launchControl: SystemLaunchControl())
        let desired = reconciler.desiredPlists(config: config, resolved: resolved, tenderExecutable: executable)
        let plan = reconciler.plan(config: config, desired: desired,
                                   agentPlist: LaunchAgentBuilder.agentPlist(executable: executable, paths: paths))

        let width = max(12, (plan.changes.map(\.name.count).max() ?? 0) + 2)
        if !plan.hasChanges {
            for change in plan.changes { print("\(Terminal.green("✓")) \(Terminal.pad(change.name, width)) \(Terminal.dim(change.summary))") }
            print("Nothing to do. The Mac already matches config.yaml.")
            return
        }
        print(dryRun ? "Apply would:" : "Applying:")
        for change in plan.changes {
            let mark = change.changesSomething ? Terminal.amber("→") : Terminal.dim("·")
            print("\(mark) \(Terminal.pad(change.name, width)) \(change.changesSomething ? change.summary : Terminal.dim(change.summary))")
        }
        if dryRun { return }

        print("")
        fflush(stdout)
        let outcomes = reconciler.apply(plan, config: config, resolved: resolved, build: !noBuild) { message in
            print(Terminal.dim(message))
            fflush(stdout) // before the build's own output, which goes straight to the terminal
        }
        var failed = false
        for outcome in outcomes {
            switch outcome.result {
            case .done(let text): print("\(Terminal.green("✓")) \(Terminal.pad(outcome.name, width)) \(text)")
            case .skipped(let text): print("\(Terminal.dim("·")) \(Terminal.pad(outcome.name, width)) \(text)")
            case .failed(let text):
                failed = true
                print("\(Terminal.red("✗")) \(Terminal.pad(outcome.name, width)) \(text)")
            }
        }
        if failed { throw ExitCode.failure }
    }
}

// MARK: - status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show each service's process state, health and likely cause of trouble.")

    @OptionGroup var options: ConfigOption

    func run() async throws {
        _ = try options.load() // fail early, with a readable message, on a broken config
        let snapshot = await TenderSnapshot.build(paths: options.paths)
        let nameWidth = max(6, (snapshot.services.map(\.name.count).max() ?? 0) + 2)

        print(Terminal.bold(Terminal.pad("NAME", nameWidth) + Terminal.pad("PROCESS", 16) + "HEALTH"))
        for service in snapshot.services {
            let process: String
            switch service.process {
            case .running, .external(true, _): process = Terminal.green(service.process.label)
            case .crashLooping: process = Terminal.red(service.process.label)
            case .exited(let code) where code != 0: process = Terminal.red(service.process.label)
            default: process = Terminal.amber(service.process.label)
            }
            let healthText: String
            switch service.health {
            case .healthy(let detail)?: healthText = Terminal.green("healthy") + Terminal.dim(" · \(detail)")
            case .unhealthy(let detail)?:
                let note = service.healthNote.map { " · \($0)" } ?? ""
                healthText = Terminal.red("unhealthy") + Terminal.dim(" · \(detail)\(note)")
            case nil: healthText = Terminal.dim("no check")
            }
            print(Terminal.pad(service.name, nameWidth) + Terminal.pad(process, 16) + healthText)
            if case .crashLooping(let code, let exits, let window) = service.process {
                print(Terminal.pad("", nameWidth) + Terminal.dim("exit \(code), \(exits) failures in \(window)"))
            }
            if let cause = service.cause {
                print(Terminal.pad("", nameWidth) + Terminal.amber("↳ ") + cause)
            }
        }

        if let system = snapshot.system {
            print("")
            print(Terminal.bold("SYSTEM"))
            for row in system.rows {
                let value: String
                switch row.level {
                case .ok: value = Terminal.green(row.value)
                case .info: value = Terminal.dim(row.value)
                case .warn: value = Terminal.amber(row.value)
                }
                print(Terminal.pad(row.name, nameWidth + 16) + value)
            }
        }

        let problems = snapshot.services.filter(\.needsAttention).map(\.name) + (snapshot.system?.problems ?? [])
        print("")
        if problems.isEmpty {
            let what = snapshot.services.count == 1 ? "The service is" : "All \(snapshot.services.count) services are"
            print(Terminal.green("●") + " \(what) healthy.")
        } else {
            print(Terminal.amber("●") + " \(snapshot.healthyCount) of \(snapshot.services.count) services healthy. Needs attention: \(problems.joined(separator: ", ")).")
        }
    }
}

// MARK: - start / stop / restart

struct ServiceArgument: ParsableArguments {
    @Argument(help: "Service name from config.yaml.")
    var service: String
}

private func managedService(_ name: String, in config: TenderConfig) throws -> ServiceConfig {
    guard let service = config.services[name] else {
        let known = config.services.keys.sorted().joined(separator: ", ")
        throw TenderError("No service named “\(name)”. Known services: \(known).")
    }
    if let external = service.external {
        throw TenderError("\(name) is external (\(external)); Tender only watches it. Use the tool that owns it, e.g. brew services.")
    }
    return service
}

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start a service.")
    @OptionGroup var options: ConfigOption
    @OptionGroup var target: ServiceArgument

    func run() throws {
        let (paths, config) = try options.load()
        _ = try managedService(target.service, in: config)
        let control = SystemLaunchControl()
        let label = LaunchAgentBuilder.label(for: target.service)
        let url = paths.plist(forLabel: label)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TenderError("\(target.service) hasn’t been applied yet. Run `tender apply`.")
        }
        if control.isLoaded(label) {
            try control.kickstart(label, kill: false)
        } else {
            try control.bootstrap(plist: url, label: label)
        }
        print("\(Terminal.green("✓")) \(target.service) started")
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop a service until the next start or apply.")
    @OptionGroup var options: ConfigOption
    @OptionGroup var target: ServiceArgument

    func run() throws {
        let (_, config) = try options.load()
        _ = try managedService(target.service, in: config)
        try SystemLaunchControl().bootout(LaunchAgentBuilder.label(for: target.service))
        print("\(Terminal.green("✓")) \(target.service) stopped. It starts again on `tender start \(target.service)` or `tender apply`.")
    }
}

struct Restart: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rebuild (if it has a build step) and restart a service.")
    @OptionGroup var options: ConfigOption
    @OptionGroup var target: ServiceArgument

    @Flag(name: .long, help: "Skip the service's `build:` step.")
    var noBuild = false

    func run() throws {
        let (paths, config) = try options.load()
        let service = try managedService(target.service, in: config)
        let control = SystemLaunchControl()
        let label = LaunchAgentBuilder.label(for: target.service)
        let url = paths.plist(forLabel: label)
        guard let plist = LaunchAgentBuilder.read(url) else {
            throw TenderError("\(target.service) hasn’t been applied yet. Run `tender apply`.")
        }
        if !noBuild, let build = service.build {
            print(Terminal.dim("building \(target.service): \(build)"))
            let reconciler = Reconciler(paths: paths, launchControl: control)
            let cwd = service.cwd.map { PathExpander.expand($0, home: paths.home.path) }
            if !ShellServiceBuilder().build(name: target.service, command: build, cwd: cwd,
                                            environment: reconciler.buildEnvironment(service: service, plist: plist)) {
                throw TenderError("build failed; \(target.service) was left running as it was.")
            }
        }
        if control.isLoaded(label) {
            try control.kickstart(label, kill: true)
        } else {
            try control.bootstrap(plist: url, label: label)
        }
        print("\(Terminal.green("✓")) \(target.service) restarted")
    }
}

// MARK: - logs

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a service's logs.")
    @OptionGroup var options: ConfigOption
    @OptionGroup var target: ServiceArgument

    @Option(name: [.customShort("n"), .long], help: "Number of lines to show.")
    var lines = 100

    @Flag(name: .shortAndLong, help: "Keep printing new lines as they arrive.")
    var follow = false

    @Flag(help: "Only stdout.")
    var stdout = false

    @Flag(help: "Only stderr.")
    var stderr = false

    func run() throws {
        let (paths, config) = try options.load()
        guard config.services[target.service] != nil else {
            throw TenderError("No service named “\(target.service)”.")
        }
        if let external = config.services[target.service]?.external {
            throw TenderError("\(target.service) is external (\(external)); its logs are wherever its own LaunchAgent writes them.")
        }
        var files: [URL] = []
        if !stderr { files.append(paths.stdoutLog(for: target.service)) }
        if !stdout { files.append(paths.stderrLog(for: target.service)) }
        files = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else {
            print("No logs yet for \(target.service).")
            return
        }
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-n", String(lines)] + (follow ? ["-F"] : []) + files.map(\.path)
        try tail.run()
        tail.waitUntilExit()
    }
}

// MARK: - validate

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check config.yaml: schema, commands, folders, dependencies and ports.")
    @OptionGroup var options: ConfigOption

    func run() throws {
        let (paths, config) = try options.load()
        let resolved = try resolveCommands(config)
        let issues = Validator(home: paths.home.path).validate(config, resolved: resolved)

        let width = max(12, (config.services.keys.map(\.count).max() ?? 0) + 2)
        for name in DependencyOrder.sorted(config) {
            let service = config.services[name]!
            if let external = service.external {
                print("\(Terminal.pad(name, width)) \(Terminal.dim("external: \(external)"))")
            } else if let command = service.command {
                let path = resolved.commands[command]?.path ?? Terminal.red("not found")
                print("\(Terminal.pad(name, width)) \(command) → \(path)")
            }
        }
        if !issues.isEmpty { print("") }
        Terminal.printIssues(issues)
        let errors = issues.filter { $0.severity == .error }.count
        let warnings = issues.count - errors
        print("")
        if errors > 0 {
            print(Terminal.red("✗") + " \(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s").")
            throw ExitCode.failure
        }
        print(Terminal.green("✓") + " Valid" + (warnings > 0 ? " with \(warnings) warning\(warnings == 1 ? "" : "s")." : "."))
    }
}

// MARK: - run (what launchd starts)

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a service in the foreground with Tender's logging (this is what LaunchAgents call).",
        shouldDisplay: false
    )

    @Argument(help: "Service name.")
    var service: String

    @Option(help: "Folder for <service>.stdout.log and <service>.stderr.log.")
    var logDir: String

    @Option(help: "Rotate logs past this many bytes.")
    var maxLogSize: Int = 10 << 20

    @Option(help: "How many rotated logs to keep.")
    var keepLogs: Int = 3

    @Option(help: "Event log used to detect crash loops.")
    var events: String?

    @Option(help: "Env file loaded at start.")
    var envFile: String?

    @Option(help: "host:port to wait for before starting (repeatable).")
    var waitFor: [String] = []

    @Option(help: "host:port that, if already answering, means a copy is running: watch it instead of starting another.")
    var adopt: String?

    @Argument(parsing: .postTerminator, help: "-- command and arguments")
    var command: [String] = []

    func run() throws {
        guard let executable = command.first else {
            throw ValidationError("Pass the command after --.")
        }
        let waits = try waitFor.map { text -> HostPort in
            guard let endpoint = HostPort(parsing: text) else { throw ValidationError("--wait-for expects host:port, got \(text)") }
            return endpoint
        }
        let options = RunnerOptions(
            name: service,
            logDir: URL(fileURLWithPath: logDir),
            maxLogSize: maxLogSize,
            keepLogs: keepLogs,
            eventsFile: events.map { URL(fileURLWithPath: $0) },
            envFile: envFile.map { URL(fileURLWithPath: $0) },
            waitFor: waits,
            adopt: try adopt.map { text in
                guard let endpoint = HostPort(parsing: text) else { throw ValidationError("--adopt expects host:port, got \(text)") }
                return endpoint
            },
            command: executable,
            arguments: Array(command.dropFirst())
        )
        let runner = try ServiceRunner(options: options)
        Foundation.exit(runner.run())
    }
}

// MARK: - doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check whether this Mac will keep serving without you: updates, login, power, lid, Tailscale, tender-agent.")
    @OptionGroup var options: ConfigOption

    func run() throws {
        let (paths, config) = try options.load()
        let facts = SystemProbe(paths: paths).gather()
        let checks = Readiness.evaluate(facts, config: config)
        for check in checks {
            let icon: String
            switch check.level {
            case .ok: icon = Terminal.green("✓")
            case .info: icon = Terminal.dim("●")
            case .warn: icon = Terminal.amber("!")
            }
            print("\(icon) \(Terminal.bold(check.title))")
            print("  " + Terminal.dim(check.detail))
            if let fix = check.fix { print("  " + Terminal.amber("→ ") + fix) }
        }
        let warnings = Readiness.warnings(checks).count
        print("")
        if warnings == 0 {
            print(Terminal.green("●") + " Nothing found that would stop this Mac serving on its own.")
        } else {
            print(Terminal.amber("●") + " \(warnings) thing\(warnings == 1 ? "" : "s") could stop this Mac serving without you.")
        }
    }
}

// MARK: - agent (what launchd runs to keep the Mac awake, and later check health)

struct Agent: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run tender-agent in the foreground (its LaunchAgent calls this).",
        shouldDisplay: false
    )
    @OptionGroup var options: ConfigOption

    @Option(help: "Seconds between checks.")
    var interval: Double = 5

    func run() throws {
        TenderAgent(paths: options.paths, interval: interval).runForever()
    }
}

// MARK: - uninstall

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop and remove every LaunchAgent Tender installed, tender-agent included. Config and logs are kept.")
    @OptionGroup var options: ConfigOption

    func run() throws {
        let reconciler = Reconciler(paths: options.paths, launchControl: SystemLaunchControl())
        let outcomes = reconciler.uninstall()
        if outcomes.isEmpty {
            print("Nothing to remove: no Tender LaunchAgents are installed.")
            return
        }
        var failed = false
        for outcome in outcomes {
            switch outcome.result {
            case .done(let text), .skipped(let text): print("\(Terminal.green("✓")) \(outcome.name): \(text)")
            case .failed(let text):
                failed = true
                print("\(Terminal.red("✗")) \(outcome.name): \(text)")
            }
        }
        print(Terminal.dim("Config (\(options.paths.configFile.path)) and logs (\(options.paths.logsDir.path)) were left in place."))
        if failed { throw ExitCode.failure }
    }
}

// MARK: - alerts

struct Alerts: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show recent alerts, or send a test notification.")
    @OptionGroup var options: ConfigOption

    @Option(name: [.customShort("n"), .long], help: "How many recent alerts to show.")
    var count = 20

    @Flag(help: "Send a test notification to check macOS shows Tender's alerts.")
    var test = false

    func run() throws {
        let paths = options.paths
        if test {
            let alert = AlertMessage(time: Date(), kind: .info, title: "Test alert",
                                     body: "If you can read this, Tender’s alerts reach this Mac.")
            OsascriptNotifier().deliver(alert)
            AlertLog(url: paths.alertsFile).append(alert)
            print("\(Terminal.green("✓")) Sent. If nothing appeared, allow notifications for Script Editor in System Settings → Notifications.")
            return
        }
        let alerts = AlertLog(url: paths.alertsFile).recent(count)
        guard !alerts.isEmpty else {
            print("No alerts yet.")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM HH:mm"
        for alert in alerts {
            let mark: String
            switch alert.kind {
            case .problem: mark = Terminal.red("●")
            case .recovery: mark = Terminal.green("●")
            case .info: mark = Terminal.dim("●")
            }
            print("\(mark) \(Terminal.dim(formatter.string(from: alert.time)))  \(Terminal.bold(alert.title))")
            print("  " + alert.body)
        }
        let open = IncidentState.read(from: paths.incidentsFile).open.values.sorted { $0.openedAt < $1.openedAt }
        if !open.isEmpty {
            print("")
            print(Terminal.bold("Open: ") + open.map(\.title).joined(separator: "; "))
        }
    }
}
