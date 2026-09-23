import Foundation
import Testing
@testable import TenderCore

@Suite("Health monitor")
struct HealthMonitorTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func config(interval: String = "30s") throws -> TenderConfig {
        try ConfigLoader.parse("""
        services:
          web: { command: x, health: { type: tcp, port: 1, interval: \(interval) } }
          quiet: { command: x }
        """)
    }

    @Test func checksOnlyWhenDueAndTracksSince() throws {
        let results = ResultQueue([.healthy(detail: "up"), .unhealthy(detail: "port 1 closed"), .unhealthy(detail: "port 1 closed")])
        let monitor = HealthMonitor(probe: { _ in results.next() })
        let config = try config()

        #expect(monitor.runDueChecks(config: config, now: t0)["web"]?.healthy == true)
        #expect(monitor.runDueChecks(config: config, now: t0.addingTimeInterval(10))["web"]?.lastChecked == t0) // not due yet
        let down = monitor.runDueChecks(config: config, now: t0.addingTimeInterval(30))["web"]!
        #expect(!down.healthy)
        #expect(down.since == t0.addingTimeInterval(30))
        let still = monitor.runDueChecks(config: config, now: t0.addingTimeInterval(35))["web"]!
        #expect(still.lastChecked == t0.addingTimeInterval(35)) // failing: rechecked after 5s, not 30s
        #expect(still.since == t0.addingTimeInterval(30)) // unhealthy since the first failure
        #expect(still.consecutiveFailures == 2)
        #expect(monitor.states["quiet"] == nil)
    }

    @Test func forgetsServicesThatLeaveTheConfig() throws {
        let monitor = HealthMonitor(probe: { _ in .healthy(detail: "up") })
        monitor.runDueChecks(config: try config(), now: t0)
        monitor.runDueChecks(config: TenderConfig(), now: t0.addingTimeInterval(60))
        #expect(monitor.states.isEmpty)
    }
}

final class ResultQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [HealthResult]

    init(_ results: [HealthResult]) { self.results = results }

    func next() -> HealthResult {
        lock.withLock { results.count > 1 ? results.removeFirst() : results[0] }
    }
}

@Suite("Incidents and alerts")
struct IncidentEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let config = TenderConfig(services: ["web": ServiceConfig(command: "pnpm"), "api": ServiceConfig(command: "node")])

    func health(_ healthy: Bool, since: TimeInterval, detail: String = "connection refused") -> ServiceHealth {
        ServiceHealth(healthy: healthy, detail: detail, since: t0.addingTimeInterval(since), lastChecked: t0, consecutiveFailures: healthy ? 0 : 3)
    }

    let loop = ProcessState.crashLooping(lastExit: 127, exits: 14, window: DurationValue(seconds: 300))

    func run(_ state: IncidentState, _ services: [String: ServiceObservation], at offset: TimeInterval = 0,
             readiness: [ReadinessCheck]? = nil) -> (IncidentState, [AlertMessage]) {
        IncidentEngine.evaluate(previous: state, services: services, readinessWarnings: readiness, config: config, now: t0.addingTimeInterval(offset))
    }

    @Test func crashLoopAlertsOnceWithTheCause() {
        let observation = ServiceObservation(crashLoop: loop, cause: "pnpm moved: nvm switched versions since the last apply.")
        let (state, alerts) = run(IncidentState(), ["web": observation])
        #expect(alerts.map(\.title) == ["web is crash-looping"])
        #expect(alerts.first?.body == "Exit 127, 14 restarts in 5m. Pnpm moved: nvm switched versions since the last apply.")
        let (_, again) = run(state, ["web": observation], at: 5)
        #expect(again.isEmpty)
    }

    @Test func unhealthyWaitsForTheGracePeriod() {
        let (state, early) = run(IncidentState(), ["api": ServiceObservation(health: health(false, since: -60))])
        #expect(early.isEmpty) // 1 minute < 2 minutes
        let (next, late) = run(state, ["api": ServiceObservation(health: health(false, since: -60))], at: 65)
        #expect(late.map(\.title) == ["api is unhealthy"])
        #expect(late.first?.body == "Connection refused. Failing for 2m.")
        #expect(next.open["unhealthy:api"] != nil)
    }

    @Test func recoverySendsOneMessage() {
        let (state, _) = run(IncidentState(), ["api": ServiceObservation(health: health(false, since: -300))])
        let (closed, alerts) = run(state, ["api": ServiceObservation(health: health(true, since: 0))], at: 120)
        #expect(alerts.map(\.title) == ["api is healthy again"])
        #expect(alerts.first?.kind == .recovery)
        #expect(alerts.first?.body == "Back after 7m.")
        #expect(closed.open.isEmpty)
        let (_, none) = run(closed, ["api": ServiceObservation(health: health(true, since: 0))], at: 125)
        #expect(none.isEmpty)
    }

    @Test func noUnhealthyAlertOnTopOfACrashLoop() {
        let (state, first) = run(IncidentState(), ["web": ServiceObservation(crashLoop: loop, health: health(false, since: -600))])
        #expect(first.map(\.title) == ["web is crash-looping"])
        // The loop ends (failures age out of the window) but it's still down: same incident, no new alert.
        let (next, second) = run(state, ["web": ServiceObservation(health: health(false, since: -600))], at: 300)
        #expect(second.isEmpty)
        #expect(next.open["unhealthy:web"] != nil)
        let (_, third) = run(next, ["web": ServiceObservation(health: health(true, since: 0))], at: 400)
        #expect(third.map(\.title) == ["web is healthy again"])
    }

    @Test func serviceWithoutHealthCheckRecoversWhenTheLoopEnds() {
        let (state, _) = run(IncidentState(), ["web": ServiceObservation(crashLoop: loop)])
        let (_, alerts) = run(state, ["web": ServiceObservation()], at: 400)
        #expect(alerts.map(\.title) == ["web is healthy again"])
    }

    @Test func readinessWarningsAlertOnceAndCloseQuietly() {
        let updates = ReadinessCheck("updates", .warn, "macOS installs updates and restarts on its own", "…", fix: "Turn it off.")
        let (state, alerts) = run(IncidentState(), [:], readiness: [updates])
        #expect(alerts.map(\.body) == ["Turn it off."])
        let (same, none) = run(state, [:], at: 300, readiness: [updates])
        #expect(none.isEmpty)
        let (unchanged, _) = run(same, [:], at: 400, readiness: nil) // not evaluated this tick
        #expect(unchanged.open["readiness:updates"] != nil)
        let (fixed, quiet) = run(unchanged, [:], at: 600, readiness: [])
        #expect(quiet.isEmpty)
        #expect(fixed.open.isEmpty)
    }

    @Test func removedServicesCloseSilently() {
        var state = IncidentState()
        state.open["crash-loop:gone"] = Incident(key: "crash-loop:gone", kind: .crashLoop, service: "gone", openedAt: t0, title: "gone is crash-looping")
        let (next, alerts) = run(state, [:])
        #expect(alerts.isEmpty)
        #expect(next.open.isEmpty)
    }

    @Test func downtimeReport() {
        let heartbeat = t0.addingTimeInterval(-5 * 3600)
        let restarted = IncidentEngine.downtime(previousHeartbeat: heartbeat, bootTime: t0.addingTimeInterval(-60), agentStart: t0)
        #expect(restarted?.title == "This Mac restarted")
        #expect(restarted?.body.contains("about 5h 0m") == true)
        let stopped = IncidentEngine.downtime(previousHeartbeat: heartbeat, bootTime: t0.addingTimeInterval(-86_400), agentStart: t0)
        #expect(stopped?.title == "Tender was stopped")
        #expect(IncidentEngine.downtime(previousHeartbeat: t0.addingTimeInterval(-30), bootTime: nil, agentStart: t0) == nil)
        #expect(IncidentEngine.downtime(previousHeartbeat: nil, bootTime: nil, agentStart: t0) == nil)
    }

    @Test func incidentStateRoundTrips() throws {
        let home = try TempHome()
        var state = IncidentState()
        state.open["unhealthy:api"] = Incident(key: "unhealthy:api", kind: .unhealthy, service: "api", openedAt: t0, title: "api is unhealthy")
        try state.write(to: home.paths.incidentsFile)
        #expect(IncidentState.read(from: home.paths.incidentsFile) == state)
    }

    @Test func appleScriptQuoting() {
        #expect(OsascriptNotifier.quote(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
    }
}

@Suite("tender-agent alerts", .serialized)
struct AgentAlertTests {
    @Test func crashLoopingServiceAlertsThroughTheAgentOnce() throws {
        let home = try TempHome()
        try home.write(".config/tender/config.yaml", "services:\n  web: { command: /bin/false }\n")
        let now = Date()
        let events = EventLog(url: home.paths.events(for: "web"))
        for offset in [-40.0, -30, -20] {
            events.append(ServiceEvent(time: now.addingTimeInterval(offset - 0.1), kind: .start))
            events.append(ServiceEvent(time: now.addingTimeInterval(offset), kind: .exit, code: 1))
        }
        let notifier = FakeNotifier()
        let agent = TenderAgent(paths: home.paths, power: FakePower(), powerSource: { PowerInfo(hasBattery: false, onACPower: true) },
                                monitor: HealthMonitor(probe: { _ in .healthy(detail: "ok") }), notifier: notifier,
                                facts: { SystemFacts(fileVaultOn: true, autoInstallMacOSUpdates: false) })
        let state = agent.tick(now: now)
        agent.tick(now: now.addingTimeInterval(5))
        #expect(notifier.titles == ["web is crash-looping"])
        #expect(state.lastAlert?.title == "web is crash-looping")
        #expect(AlertLog(url: home.paths.alertsFile).recent(10).count == 1)

        // A fresh agent (after a restart) remembers the open incident and doesn't repeat it.
        let restarted = TenderAgent(paths: home.paths, power: FakePower(), powerSource: { PowerInfo(hasBattery: false, onACPower: true) },
                                    monitor: HealthMonitor(probe: { _ in .healthy(detail: "ok") }), notifier: notifier,
                                    facts: { SystemFacts(fileVaultOn: true, autoInstallMacOSUpdates: false) })
        restarted.tick(now: now.addingTimeInterval(10))
        #expect(notifier.titles.count == 1)
    }

    @Test func alertsOffStillLogsButDoesntNotify() throws {
        let home = try TempHome()
        try home.write(".config/tender/config.yaml", "alerts: { macos: false }\n")
        let notifier = FakeNotifier()
        let agent = TenderAgent(paths: home.paths, power: FakePower(), powerSource: { PowerInfo(hasBattery: false, onACPower: true) },
                                monitor: HealthMonitor(probe: { _ in .healthy(detail: "ok") }), notifier: notifier,
                                facts: { SystemFacts(fileVaultOn: false, autoInstallMacOSUpdates: true) })
        agent.tick()
        #expect(notifier.titles.isEmpty)
        #expect(AlertLog(url: home.paths.alertsFile).recent(10).map(\.title).contains("macOS installs updates and restarts on its own"))
    }
}
