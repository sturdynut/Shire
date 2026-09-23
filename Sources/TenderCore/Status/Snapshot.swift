import Foundation

/// Everything `tender status`, the menu bar and the phone page show, computed one way in one place.
public struct TenderSnapshot: Sendable {
    public enum Overall: Equatable, Sendable {
        case healthy
        case attention(count: Int)
        /// No config, or tender-agent isn't running, so nothing is being looked after.
        case notRunning(reason: String)
    }

    public struct Service: Identifiable, Sendable {
        public var id: String { name }
        public var name: String
        public var config: ServiceConfig
        public var process: ProcessState
        public var health: HealthResult?
        /// "for 3m" when failing, "checked 12s ago" when healthy (only when tender-agent tracks it).
        public var healthNote: String?
        public var unhealthySince: Date?
        public var cause: String?
        /// A local http URL to open the service in a browser, when its health check is http.
        public var url: URL?

        public var needsAttention: Bool { process.isProblem || health?.isHealthy == false }
    }

    public var time: Date
    public var configError: String?
    public var config: TenderConfig?
    public var services: [Service]
    public var agent: AgentState?
    public var facts: SystemFacts?
    public var system: SystemSummary?
    public var readiness: [ReadinessCheck]
    public var incidents: [Incident]
    public var recentAlerts: [AlertMessage]

    public var healthyCount: Int { services.filter { !$0.needsAttention }.count }

    public var overall: Overall {
        if let configError { return .notRunning(reason: configError) }
        if agent == nil { return .notRunning(reason: "tender-agent isn’t running") }
        let problems = services.filter(\.needsAttention).count + (system?.problems.count ?? 0)
        return problems == 0 ? .healthy : .attention(count: problems)
    }

    /// Builds a snapshot. `includeSystem` gathers readiness facts, which takes most of a second; the menu bar asks
    /// for them less often than it refreshes services.
    public static func build(paths: TenderPaths, launchControl: LaunchControl = SystemLaunchControl(),
                             includeSystem: Bool = true, facts: SystemFacts? = nil, now: Date = Date()) async -> TenderSnapshot {
        let incidents = IncidentState.read(from: paths.incidentsFile).open.values.sorted { $0.openedAt < $1.openedAt }
        let alerts = AlertLog(url: paths.alertsFile).recent(30).reversed()
        let agent = AgentState.read(from: paths.agentStateFile).flatMap { $0.isFresh(now: now) ? $0 : nil }

        let config: TenderConfig
        do {
            config = try ConfigLoader.load(from: paths.configFile)
        } catch {
            return TenderSnapshot(time: now, configError: String(describing: error), config: nil, services: [], agent: agent,
                                  facts: nil, system: nil, readiness: [], incidents: incidents, recentAlerts: Array(alerts))
        }

        let inspector = StatusInspector(paths: paths, launchControl: launchControl, crashLoop: config.alerts.crashLoop)
        let names = DependencyOrder.sorted(config)

        // The agent's tracked health knows how long something has been failing; check directly only what it doesn't track.
        var health: [String: HealthResult] = [:]
        var notes: [String: String] = [:]
        var since: [String: Date] = [:]
        for (name, state) in agent?.services ?? [:] {
            health[name] = state.healthy ? .healthy(detail: state.detail) : .unhealthy(detail: state.detail)
            notes[name] = state.healthy ? "checked \(Readiness.describe(now.timeIntervalSince(state.lastChecked))) ago"
                                        : "for \(Readiness.describe(now.timeIntervalSince(state.since)))"
            if !state.healthy { since[name] = state.since }
        }
        let untracked = names.filter { health[$0] == nil && config.services[$0]?.health != nil }
        await withTaskGroup(of: (String, HealthResult).self) { group in
            for name in untracked {
                let check = config.services[name]!.health!
                group.addTask { (name, await HealthProbe.check(check)) }
            }
            for await (name, result) in group { health[name] = result }
        }

        var services: [Service] = []
        for name in names {
            let service = config.services[name]!
            let state = inspector.processState(name: name, service: service, now: now)
            let cause = inspector.likelyCause(name: name, service: service, state: state, dependencyHealth: health)
            var url: URL?
            if let check = service.health, check.type == .http, let text = check.url { url = URL(string: text) }
            services.append(Service(name: name, config: service, process: state, health: health[name], healthNote: notes[name],
                                    unhealthySince: since[name], cause: cause, url: url))
        }

        var gathered = facts
        if gathered == nil, includeSystem { gathered = SystemProbe(paths: paths, launchControl: launchControl).gather() }
        let system = gathered.map { SystemSummary(facts: $0, config: config, now: now) }
        let readiness = gathered.map { Readiness.evaluate($0, config: config, now: now) } ?? []
        return TenderSnapshot(time: now, configError: nil, config: config, services: services, agent: agent, facts: gathered,
                              system: system, readiness: readiness, incidents: incidents, recentAlerts: Array(alerts))
    }
}
