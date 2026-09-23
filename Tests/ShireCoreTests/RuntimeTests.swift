import Foundation
import Testing
@testable import ShireCore

@Suite("Env files")
struct EnvFileTests {
    @Test func parsesCommonShapes() {
        let values = EnvFile.parse("""
        # demo database
        DATABASE_URL=postgresql://me@localhost:5432/bagend_demo
        export NODE_ENV=production
        QUOTED="hello world"
        SINGLE='a # not a comment'
        TRAILING=value # comment
        ESCAPED="line1\\nline2"
        not a line
        =novalue
        """)
        #expect(values["DATABASE_URL"] == "postgresql://me@localhost:5432/bagend_demo")
        #expect(values["NODE_ENV"] == "production")
        #expect(values["QUOTED"] == "hello world")
        #expect(values["SINGLE"] == "a # not a comment")
        #expect(values["TRAILING"] == "value")
        #expect(values["ESCAPED"] == "line1\nline2")
        #expect(values.count == 6)
    }
}

@Suite("Rotating logs")
struct RotatingLogTests {
    @Test func rotatesAndKeepsOnlyN() throws {
        let home = try TempHome()
        let url = home.url.appending(path: "svc.stdout.log")
        let log = try RotatingLog(url: url, maxBytes: 1024, keep: 2)
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 600)
        for _ in 0..<6 { log.write(chunk) }

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: url.path))
        #expect(fm.fileExists(atPath: url.path + ".1"))
        #expect(fm.fileExists(atPath: url.path + ".2"))
        #expect(!fm.fileExists(atPath: url.path + ".3"))
        let size = try fm.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect((size ?? 0) <= 1024)
    }

    @Test func tailReadsTheLastLines() throws {
        let home = try TempHome()
        let url = try home.write("log.txt", (1...500).map { "line \($0)" }.joined(separator: "\n") + "\n")
        #expect(LogReader.tail(url, lines: 3) == ["line 498", "line 499", "line 500"])
        #expect(LogReader.tail(url, lines: 2, maxBytes: 30) == ["line 499", "line 500"])
    }
}

@Suite("Status")
struct StatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let rule = CrashLoopRule.default

    func exits(_ offsets: [TimeInterval], code: Int32 = 127) -> [ServiceEvent] {
        offsets.flatMap { offset in
            [ServiceEvent(time: now.addingTimeInterval(offset - 0.05), kind: .start),
             ServiceEvent(time: now.addingTimeInterval(offset), kind: .exit, code: code)]
        }
    }

    @Test func threeFailuresInFiveMinutesIsACrashLoop() {
        let state = StatusInspector.crashLoop(in: exits([-40, -30, -20]), rule: rule, now: now)
        #expect(state == .crashLooping(lastExit: 127, exits: 3, window: DurationValue(seconds: 300)))
    }

    @Test func oldOrFewFailuresAreNot() {
        #expect(StatusInspector.crashLoop(in: exits([-40, -30]), rule: rule, now: now) == nil)
        #expect(StatusInspector.crashLoop(in: exits([-900, -800, -700]), rule: rule, now: now) == nil)
        #expect(StatusInspector.crashLoop(in: exits([-40, -30, -20], code: 0), rule: rule, now: now) == nil)
    }

    @Test func recoveredServiceIsNoLongerCrashLooping() {
        var events = exits([-200, -190, -180])
        events.append(ServiceEvent(time: now.addingTimeInterval(-120), kind: .start))
        #expect(StatusInspector.crashLoop(in: events, rule: rule, now: now) == nil)
    }

    @Test func eventLogRoundTrips() throws {
        let home = try TempHome()
        let log = EventLog(url: home.url.appending(path: "events/web.jsonl"))
        for event in exits([-3, -2, -1]) { log.append(event) }
        let read = log.read()
        #expect(read.count == 6)
        #expect(read.last?.code == 127)
    }

    @Test func likelyCauseNamesTheNvmSwitch() throws {
        let home = try TempHome()
        let config = try ConfigLoader.parse(planConfigYAML)
        let control = FakeLaunchControl()
        let reconciler = Reconciler(paths: home.paths, launchControl: control, builder: FakeBuilder(succeeds: true))
        let desired = reconciler.desiredPlists(config: config, resolved: planResolution(), shireExecutable: "/u")
        _ = reconciler.apply(reconciler.plan(config: config, desired: desired), config: config, resolved: planResolution(), build: true)

        let inspector = StatusInspector(paths: home.paths, launchControl: control, crashLoop: rule,
                                        fileExists: { !$0.contains("/.nvm/") && FileManager.default.fileExists(atPath: $0) },
                                        directoryExists: { _ in true })
        let cause = inspector.likelyCause(
            name: "bagend-web", service: config.services["bagend-web"]!,
            state: .crashLooping(lastExit: 127, exits: 14, window: rule.window),
            dependencyHealth: ["bagend-api": .healthy(detail: "ok")])
        #expect(cause == "pnpm moved: nvm switched versions since the last apply. Run `shire apply` to re-resolve.")
    }

    @Test func likelyCausePointsAtADownDependency() throws {
        let home = try TempHome()
        let config = try ConfigLoader.parse(planConfigYAML)
        let inspector = StatusInspector(paths: home.paths, launchControl: FakeLaunchControl(), crashLoop: rule, directoryExists: { _ in true })
        let cause = inspector.likelyCause(
            name: "bagend-api", service: config.services["bagend-api"]!,
            state: .exited(code: 75), dependencyHealth: ["postgres": .unhealthy(detail: "port 5432 closed")])
        #expect(cause == "postgres isn’t reachable (port 5432 closed), so bagend-api is waiting for it.")
    }

    @Test func likelyCauseReadsPortClashesFromTheLog() throws {
        let home = try TempHome()
        try home.write("Library/Logs/shire/web.stderr.log", "Error: listen EADDRINUSE: address already in use :::5174\n")
        let inspector = StatusInspector(paths: home.paths, launchControl: FakeLaunchControl(), crashLoop: rule)
        let cause = inspector.likelyCause(name: "web", service: ServiceConfig(command: "pnpm"), state: .exited(code: 1), dependencyHealth: [:])
        #expect(cause == "its port is already in use by another process.")
    }

    @Test func externalServiceState() throws {
        let home = try TempHome()
        let control = FakeLaunchControl(loaded: ["homebrew.mxcl.postgresql@16": LaunchJobInfo(state: "running", pid: 739)])
        let inspector = StatusInspector(paths: home.paths, launchControl: control, crashLoop: rule)
        #expect(inspector.processState(name: "postgres", service: ServiceConfig(external: "homebrew.mxcl.postgresql@16")) == .external(running: true, pid: 739))
        #expect(inspector.processState(name: "x", service: ServiceConfig(external: "missing")) == .externalMissing(label: "missing"))
    }
}

@Suite("shire run", .serialized)
struct ServiceRunnerTests {
    func options(_ home: TempHome, _ command: String, _ args: [String] = [], envFile: URL? = nil, waitFor: [HostPort] = [], waitTimeout: TimeInterval = 120) -> RunnerOptions {
        RunnerOptions(name: "svc", logDir: home.url.appending(path: "logs"), maxLogSize: 1 << 20, keepLogs: 2,
                      eventsFile: home.url.appending(path: "events/svc.jsonl"), envFile: envFile,
                      waitFor: waitFor, waitTimeout: waitTimeout, command: command, arguments: args)
    }

    func log(_ home: TempHome, _ stream: String) throws -> String {
        try String(contentsOf: home.url.appending(path: "logs/svc.\(stream).log"), encoding: .utf8)
    }

    @Test func capturesOutputAndExitCode() throws {
        let home = try TempHome()
        let runner = try ServiceRunner(options: options(home, "/bin/sh", ["-c", "echo hello; echo oops >&2; exit 3"]))
        #expect(runner.run() == 3)
        #expect(try log(home, "stdout").contains("hello"))
        #expect(try log(home, "stderr").contains("oops"))
        #expect(try log(home, "stderr").contains("shire: exited 3"))
        let events = EventLog(url: home.url.appending(path: "events/svc.jsonl")).read()
        #expect(events.map(\.kind) == [.start, .exit])
        #expect(events.last?.code == 3)
    }

    @Test func missingNvmCommandExplainsItself() throws {
        let home = try TempHome()
        let missing = "/Users/nobody/.nvm/versions/node/v22.14.0/bin/pnpm"
        let runner = try ServiceRunner(options: options(home, missing))
        #expect(runner.run() == 127)
        let stderr = try log(home, "stderr")
        #expect(stderr.contains("no such file: \(missing)"))
        #expect(stderr.contains("nvm switched versions"))
    }

    @Test func loadsTheEnvFile() throws {
        let home = try TempHome()
        let envFile = try home.write(".env.demo", "DATABASE_URL=postgresql://localhost/demo\n")
        let runner = try ServiceRunner(options: options(home, "/bin/sh", ["-c", "echo \"db=$DATABASE_URL\""], envFile: envFile))
        #expect(runner.run() == 0)
        #expect(try log(home, "stdout").contains("db=postgresql://localhost/demo"))
    }

    @Test func givesUpOnAnUnreachableDependency() throws {
        let home = try TempHome()
        let runner = try ServiceRunner(options: options(home, "/bin/echo", ["never"], waitFor: [HostPort(host: "127.0.0.1", port: 1)], waitTimeout: 1.5))
        #expect(runner.run() == ServiceRunner.exitDependencyTimeout)
        #expect(try log(home, "stderr").contains("gave up waiting for 127.0.0.1:1"))
        #expect(try !log(home, "stdout").contains("never\n"))
    }

    @Test func tcpProbe() throws {
        #expect(!HealthProbe.tcpConnect(HostPort(host: "127.0.0.1", port: 1), timeout: 0.5))
    }
}
