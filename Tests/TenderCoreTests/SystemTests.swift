import Foundation
import Testing
@testable import TenderCore

@Suite("System fact parsers")
struct SystemParserTests {
    @Test func fileVault() {
        #expect(SystemProbe.parseFileVault("FileVault is On.\n") == true)
        #expect(SystemProbe.parseFileVault("FileVault is Off.\n") == false)
        #expect(SystemProbe.parseFileVault("Error") == nil)
    }

    @Test func pmsetOutput() {
        let output = """
        System-wide power settings:
        Currently in use:
         standby              1
         Sleep On Power Button 1
         autorestart          1
         sleep                1 (sleep prevented by Claude, caffeinate)
         displaysleep         10 (display sleep prevented by caffeinate)
        """
        let values = SystemProbe.parsePmset(output)
        #expect(values["autorestart"] == "1")
        #expect(values["sleep"] == "1 (sleep prevented by Claude, caffeinate)")
        #expect(values["displaysleep"]?.hasPrefix("10") == true)
    }

    @Test func softwareUpdatePreferences() {
        let prefs: [String: Any] = [
            "AutomaticallyInstallMacOSUpdates": NSNumber(value: 1),
            "RecommendedUpdates": [["Display Name": "macOS 27"], ["Display Name": "Command Line Tools for Xcode 26.5"]],
        ]
        let (autoInstall, pending) = SystemProbe.parseSoftwareUpdate(prefs)
        #expect(autoInstall == true)
        #expect(pending == ["macOS 27", "Command Line Tools for Xcode 26.5"])
        #expect(SystemProbe.parseSoftwareUpdate([:]).0 == nil)
    }

    @Test func tailscaleConnected() {
        let json = """
        {"Version":"1.98.5","BackendState":"Running",
         "Self":{"HostName":"Mattis-MacBook-Pro-2","DNSName":"mattis-macbook-pro-2.tailf6643a.ts.net.",
                 "TailscaleIPs":["100.79.19.37","fd7a:115c:a1e0::5701:13d5"]}}
        """
        #expect(Tailscale.parse(json: json) == .connected(hostName: "Mattis-MacBook-Pro-2",
                                                          dnsName: "mattis-macbook-pro-2.tailf6643a.ts.net",
                                                          ipv4: "100.79.19.37"))
    }

    @Test func tailscaleStates() {
        #expect(Tailscale.parse(json: "{\"BackendState\":\"NeedsLogin\"}") == .notConnected(backendState: "NeedsLogin"))
        #expect(Tailscale.parse(json: "", stderr: "failed to connect to local tailscaled") == .daemonNotRunning(detail: "failed to connect to local tailscaled"))
        #expect(Tailscale.status(runner: FakeRunner(stdout: ""), cli: nil) == .notInstalled)
        #expect(Tailscale.locateCLI(fileExists: { $0 == "/opt/homebrew/bin/tailscale" }) == "/opt/homebrew/bin/tailscale")
    }
}

@Suite("Readiness")
struct ReadinessTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func agentState(held: Bool = true, reason: String = "on power", age: TimeInterval = 2, configError: String? = nil) -> AgentState {
        AgentState(pid: 321, startedAt: now.addingTimeInterval(-600), updatedAt: now.addingTimeInterval(-age),
                   configPath: "/c", configError: configError, keepAwake: .init(wanted: true, held: held, reason: reason))
    }

    /// This Mac as found: FileVault on, updates auto-install, MacBook on power with a display, Tailscale connected.
    func thisMac() -> SystemFacts {
        SystemFacts(fileVaultOn: true, autoInstallMacOSUpdates: true, pendingUpdates: ["macOS 27"],
                    power: PowerInfo(hasBattery: true, onACPower: true, batteryPercent: 79), externalDisplays: 1,
                    diskFreeBytes: 500_000_000_000, bootTime: now.addingTimeInterval(-86_400 * 30),
                    tailscale: .connected(hostName: "mbp", dnsName: "mbp.tail.ts.net", ipv4: "100.79.19.37"),
                    agentLoaded: true, agentState: agentState())
    }

    func config(keepAwake: Bool = true, tailscale: Bool = true) -> TenderConfig {
        TenderConfig(serverMode: ServerMode(keepAwake: keepAwake), presets: Presets(tailscale: TailscalePreset(enabled: tailscale)))
    }

    func check(_ id: String, _ facts: SystemFacts, config: TenderConfig? = nil) -> ReadinessCheck? {
        Readiness.evaluate(facts, config: config ?? self.config(), now: now).first { $0.id == id }
    }

    @Test func thisMacHasOneWarningAndItIsUpdates() {
        let checks = Readiness.evaluate(thisMac(), config: config(), now: now)
        #expect(Readiness.warnings(checks).map(\.id) == ["updates"])
        #expect(checks.first { $0.id == "updates" }?.detail.contains("With FileVault on") == true)
        #expect(checks.first { $0.id == "login" }?.level == .info)
        #expect(checks.first { $0.id == "uptime" }?.title == "Up 30d 0h")
    }

    @Test func fileVaultOffWithoutAutoLoginWarns() {
        var facts = thisMac()
        facts.fileVaultOn = false
        #expect(check("login", facts)?.level == .warn)
        facts.autoLoginUser = "matti"
        #expect(check("login", facts)?.level == .ok)
    }

    @Test func lidNeedsPowerAndADisplay() {
        var facts = thisMac()
        facts.externalDisplays = 0
        #expect(check("lid", facts)?.level == .warn)
        #expect(check("lid", facts)?.detail.contains("no external display") == true)
        facts.power = PowerInfo(hasBattery: false, onACPower: true)
        #expect(check("lid", facts) == nil)
        #expect(check("power", facts) == nil)
    }

    @Test func batteryWarns() {
        var facts = thisMac()
        facts.power = PowerInfo(hasBattery: true, onACPower: false, batteryPercent: 40)
        #expect(check("power", facts)?.title == "Running on battery (40%)")
    }

    @Test func agentMissingStaleOrConfused() {
        var facts = thisMac()
        facts.agentLoaded = false
        #expect(check("agent", facts)?.title == "tender-agent isn’t installed")
        facts.agentLoaded = true
        facts.agentState = agentState(age: 120)
        #expect(check("agent", facts)?.title == "tender-agent isn’t responding")
        #expect(check("keep-awake", facts)?.level == .warn)
        facts.agentState = agentState(configError: "bad yaml")
        #expect(check("agent", facts)?.title == "tender-agent can’t read config.yaml")
    }

    @Test func keepAwakeStates() {
        var facts = thisMac()
        #expect(check("keep-awake", facts)?.level == .ok)
        facts.agentState = agentState(held: false, reason: "on battery (40%); the Mac may sleep to save it")
        #expect(check("keep-awake", facts)?.level == .warn)
        #expect(check("keep-awake", facts, config: config(keepAwake: false))?.level == .info)
    }

    @Test func tailscaleOnlyWhenThePresetIsOn() {
        var facts = thisMac()
        facts.tailscale = .notConnected(backendState: "NeedsLogin")
        #expect(check("tailscale", facts)?.fix == "Run `tailscale up` and log in.")
        #expect(check("tailscale", facts, config: config(tailscale: false)) == nil)
    }

    @Test func lowDisk() {
        var facts = thisMac()
        facts.diskFreeBytes = 3_000_000_000
        #expect(check("disk", facts)?.level == .warn)
    }

    @Test func powerLossSetting() {
        var facts = thisMac()
        #expect(check("power-loss", facts) == nil) // laptops don't offer it
        facts.power = PowerInfo(hasBattery: false, onACPower: true)
        facts.autoRestartAfterPowerLoss = false
        #expect(check("power-loss", facts)?.level == .warn)
        facts.autoRestartAfterPowerLoss = true
        #expect(check("power-loss", facts)?.level == .ok)
    }

    @Test func systemSummary() {
        var facts = thisMac()
        var summary = SystemSummary(facts: facts, config: config(), now: now)
        #expect(summary.rows.map(\.name) == ["tender-agent", "keep-awake", "tailscale", "readiness"])
        #expect(summary.problems.isEmpty)
        #expect(summary.rows.last?.value == "1 warning · run `tender doctor`")

        facts.agentState = nil
        facts.agentLoaded = false
        summary = SystemSummary(facts: facts, config: config(), now: now)
        #expect(summary.problems == ["tender-agent", "keep-awake"])
    }
}

final class FakePower: PowerAsserting {
    var isHeld = false
    var holds = 0
    var refuse = false

    func hold(reason: String) -> Bool {
        if refuse { return false }
        if !isHeld { holds += 1 }
        isHeld = true
        return true
    }

    func release() { isHeld = false }
}

@Suite("tender-agent", .serialized)
struct AgentTests {
    func makeAgent(_ home: TempHome, power: FakePower, source: @escaping () -> PowerInfo) -> TenderAgent {
        TenderAgent(paths: home.paths, interval: 1, power: power, powerSource: source)
    }

    @Test func holdsKeepAwakeOnPowerAndWritesState() throws {
        let home = try TempHome()
        try home.write(".config/tender/config.yaml", "serverMode: { keepAwake: true }\n")
        let power = FakePower()
        let agent = makeAgent(home, power: power) { PowerInfo(hasBattery: true, onACPower: true, batteryPercent: 80) }

        let state = agent.tick()
        #expect(power.isHeld)
        #expect(state.keepAwake == .init(wanted: true, held: true, reason: "on power"))
        let saved = try #require(AgentState.read(from: home.paths.agentStateFile))
        #expect(saved.keepAwake == state.keepAwake)
        #expect(saved.pid == state.pid)
        #expect(abs(saved.updatedAt.timeIntervalSince(state.updatedAt)) < 1) // stored to the second

        agent.tick()
        #expect(power.holds == 1) // not re-created every tick
    }

    @Test func releasesOnBattery() throws {
        let home = try TempHome()
        try home.write(".config/tender/config.yaml", "serverMode: { keepAwake: true }\n")
        let power = FakePower()
        var onAC = true
        let agent = makeAgent(home, power: power) { PowerInfo(hasBattery: true, onACPower: onAC, batteryPercent: 55) }
        agent.tick()
        #expect(power.isHeld)
        onAC = false
        let state = agent.tick()
        #expect(!power.isHeld)
        #expect(state.keepAwake.reason.hasPrefix("on battery (55%)"))
    }

    @Test func followsConfigChangesAndSurvivesABrokenFile() throws {
        let home = try TempHome()
        let file = try home.write(".config/tender/config.yaml", "serverMode: { keepAwake: true }\n")
        let power = FakePower()
        let agent = makeAgent(home, power: power) { PowerInfo(hasBattery: false, onACPower: true) }
        agent.tick()
        #expect(power.isHeld)

        try "serverMode: { keepAwake: false }\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        agent.tick()
        #expect(!power.isHeld)

        try "serverMode: { keepAwake: [oops\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
        let state = agent.tick()
        #expect(state.configError != nil)
        #expect(!power.isHeld) // kept the last good setting
    }

    @Test func missingConfigMeansNoKeepAwake() throws {
        let home = try TempHome()
        let power = FakePower()
        let state = makeAgent(home, power: power) { PowerInfo(hasBattery: false, onACPower: true) }.tick()
        #expect(!power.isHeld)
        #expect(state.configError?.contains("No config file") == true)
    }
}

@Suite("tender-agent install")
struct AgentInstallTests {
    @Test func applyInstallsTheAgentOnceAndNeverTreatsItAsAService() throws {
        let home = try TempHome()
        let config = try ConfigLoader.parse(planConfigYAML)
        let control = FakeLaunchControl()
        let reconciler = Reconciler(paths: home.paths, launchControl: control, builder: FakeBuilder(succeeds: true))
        let desired = reconciler.desiredPlists(config: config, resolved: planResolution(), tenderExecutable: "/u")
        let agent = LaunchAgentBuilder.agentPlist(executable: "/u", paths: home.paths)

        let plan = reconciler.plan(config: config, desired: desired, agentPlist: agent)
        #expect(plan.changes.first?.name == "tender-agent")
        #expect(plan.changes.first?.action == .install)
        _ = reconciler.apply(plan, config: config, resolved: planResolution(), build: true)
        #expect(control.calls.first == "bootstrap com.tender.agent")

        #expect(!reconciler.installedServices().contains("agent"))
        let again = reconciler.plan(config: config, desired: desired, agentPlist: agent)
        #expect(!again.hasChanges)
        #expect(!again.changes.contains { $0.action == .remove })
    }

    @Test func uninstallRemovesServicesAndTheAgent() throws {
        let home = try TempHome()
        let config = try ConfigLoader.parse(planConfigYAML)
        let control = FakeLaunchControl()
        let reconciler = Reconciler(paths: home.paths, launchControl: control, builder: FakeBuilder(succeeds: true))
        let desired = reconciler.desiredPlists(config: config, resolved: planResolution(), tenderExecutable: "/u")
        let agent = LaunchAgentBuilder.agentPlist(executable: "/u", paths: home.paths)
        _ = reconciler.apply(reconciler.plan(config: config, desired: desired, agentPlist: agent), config: config, resolved: planResolution(), build: true)

        let removed = reconciler.uninstall().map(\.name)
        #expect(Set(removed) == ["doulasimply-api", "doulasimply-web", "tradingview", "tender-agent"])
        #expect(reconciler.installedServices().isEmpty)
        #expect(!control.isLoaded(LaunchAgentBuilder.agentLabel))
        #expect(reconciler.uninstall().isEmpty)
    }

    @Test func agentNameIsReserved() throws {
        let issues = Validator(home: "/Users/me", directoryExists: { _ in true }, fileExists: { _ in true })
            .validate(try ConfigLoader.parse("services:\n  agent: { command: /bin/echo }\n"))
        #expect(issues.contains { $0.message.contains("reserved for tender-agent") })
    }
}
