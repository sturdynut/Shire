import Foundation

/// What tender-agent last did, written every tick so `tender status` and `tender doctor` can read it.
public struct AgentState: Codable, Equatable, Sendable {
    public struct KeepAwake: Codable, Equatable, Sendable {
        public var wanted: Bool
        public var held: Bool
        public var reason: String

        public init(wanted: Bool, held: Bool, reason: String) {
            self.wanted = wanted
            self.held = held
            self.reason = reason
        }
    }

    public var pid: Int32
    public var startedAt: Date
    public var updatedAt: Date
    public var configPath: String
    public var configError: String?
    public var keepAwake: KeepAwake
    /// Health as the agent has tracked it; nil in files written before health checks existed.
    public var services: [String: ServiceHealth]?
    public var lastAlert: AlertMessage?

    public init(pid: Int32, startedAt: Date, updatedAt: Date, configPath: String, configError: String?, keepAwake: KeepAwake,
                services: [String: ServiceHealth]? = nil, lastAlert: AlertMessage? = nil) {
        self.pid = pid
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.configPath = configPath
        self.configError = configError
        self.keepAwake = keepAwake
        self.services = services
        self.lastAlert = lastAlert
    }

    /// The agent ticks every few seconds; anything older than this means it stopped.
    public static let staleAfter: TimeInterval = 30

    public func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) < Self.staleAfter
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func read(from url: URL) -> AgentState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(AgentState.self, from: data)
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// tender-agent: the always-running part of Tender. It keeps the Mac awake, checks each service's health on its own
/// interval, turns problems into incidents, and sends one alert per incident plus one when it recovers.
/// It re-reads config.yaml when the file changes, so edits take effect within one tick.
public final class TenderAgent {
    public let paths: TenderPaths
    public let interval: TimeInterval
    private let power: PowerAsserting
    private let powerSource: () -> PowerInfo
    private let monitor: HealthMonitor
    private let notifier: Notifying
    private let facts: () -> SystemFacts
    private let readinessInterval: TimeInterval
    private let startedAt: Date

    private var config: TenderConfig?
    private var configError: String?
    private var configModified: Date?
    private var incidents: IncidentState
    private var lastReadiness: Date?
    private var lastAlert: AlertMessage?
    /// The heartbeat left by the previous run, used for the "services were down" report.
    private let previousHeartbeat: Date?
    /// Config and system facts, shared with the phone page's server thread.
    private let shared = LockedBox<(config: TenderConfig?, facts: SystemFacts?)>((nil, nil))
    private var phone: PhoneServer?
    private var phonePort: Int?
    private let startPhoneServer: Bool

    /// Readiness checks that aren't worth an alert: the agent can't usefully report on itself; being on battery
    /// already alerts, so "keep-awake released" would repeat it; and "the lid would sleep it" describes what *could*
    /// happen, which would buzz every time a laptop's display is unplugged.
    static let silentReadinessChecks: Set<String> = ["agent", "keep-awake", "lid"]

    public init(paths: TenderPaths, interval: TimeInterval = 5, power: PowerAsserting = PowerAssertion(),
                powerSource: @escaping () -> PowerInfo = PowerInfo.current,
                monitor: HealthMonitor = HealthMonitor(),
                notifier: Notifying = OsascriptNotifier(),
                facts: (() -> SystemFacts)? = nil,
                readinessInterval: TimeInterval = 300,
                phoneServer: Bool = true,
                now: Date = Date()) {
        self.paths = paths
        self.interval = interval
        self.power = power
        self.powerSource = powerSource
        self.monitor = monitor
        self.notifier = notifier
        self.facts = facts ?? { SystemProbe(paths: paths).gather() }
        self.readinessInterval = readinessInterval
        self.startPhoneServer = phoneServer
        self.startedAt = now
        let previous = AgentState.read(from: paths.agentStateFile)
        self.previousHeartbeat = previous?.updatedAt
        self.lastAlert = previous?.lastAlert
        self.incidents = IncidentState.read(from: paths.incidentsFile)
    }

    /// Reports a gap since the previous run (a restart, or the agent being stopped). Call once at startup.
    @discardableResult
    public func reportDowntime(bootTime: Date? = SystemProbe.bootTime()) -> AlertMessage? {
        guard let alert = IncidentEngine.downtime(previousHeartbeat: previousHeartbeat, bootTime: bootTime, agentStart: startedAt) else { return nil }
        reloadConfigIfNeeded()
        send(alert)
        return alert
    }

    /// One pass: reload config if it changed, keep-awake, health checks, incidents and alerts, then record state.
    @discardableResult
    public func tick(now: Date = Date()) -> AgentState {
        reloadConfigIfNeeded()
        let keepAwake = updateKeepAwake()
        var health: [String: ServiceHealth] = [:]
        if let config {
            health = monitor.runDueChecks(config: config, now: now)
            evaluateIncidents(config: config, health: health, now: now)
            shared.value.config = config
            if startPhoneServer { updatePhoneServer(config: config) }
        }
        let state = AgentState(
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: startedAt,
            updatedAt: now,
            configPath: paths.configFile.path,
            configError: configError,
            keepAwake: keepAwake,
            services: health,
            lastAlert: lastAlert
        )
        try? state.write(to: paths.agentStateFile)
        return state
    }

    private func evaluateIncidents(config: TenderConfig, health: [String: ServiceHealth], now: Date) {
        let inspector = StatusInspector(paths: paths, launchControl: NoLaunchControl(), crashLoop: config.alerts.crashLoop)
        let dependencyHealth = health.mapValues { $0.healthy ? HealthResult.healthy(detail: $0.detail) : .unhealthy(detail: $0.detail) }
        var observations: [String: ServiceObservation] = [:]
        for (name, service) in config.services {
            var observation = ServiceObservation(health: health[name])
            if !service.isExternal {
                let events = EventLog(url: paths.events(for: name)).read()
                if let loop = StatusInspector.crashLoop(in: events, rule: config.alerts.crashLoop, now: now) {
                    observation.crashLoop = loop
                    observation.cause = inspector.likelyCause(name: name, service: service, state: loop, dependencyHealth: dependencyHealth)
                }
            }
            observations[name] = observation
        }

        var warnings: [ReadinessCheck]?
        if lastReadiness == nil || now.timeIntervalSince(lastReadiness!) >= readinessInterval {
            lastReadiness = now
            let gathered = facts()
            shared.value.facts = gathered
            warnings = Readiness.warnings(Readiness.evaluate(gathered, config: config, now: now))
                .filter { !Self.silentReadinessChecks.contains($0.id) }
        }

        let (next, alerts) = IncidentEngine.evaluate(previous: incidents, services: observations, readinessWarnings: warnings, config: config, now: now)
        if next != incidents {
            incidents = next
            try? incidents.write(to: paths.incidentsFile)
        }
        alerts.forEach(send)
    }

    private func send(_ alert: AlertMessage) {
        AlertLog(url: paths.alertsFile).append(alert)
        lastAlert = alert
        log("alert: \(alert.title) — \(alert.body)")
        // The menu bar app reads alerts.jsonl and posts them as Tender; only fall back when it isn't running.
        if config?.alerts.macos ?? true, !AppPresence.isRunning(paths) {
            notifier.deliver(alert)
        }
        if config?.alerts.phone == true, startPhoneServer {
            let sender = WebPushSender(paths: paths)
            Task.detached { await sender.send(alert) }
        }
    }

    /// Runs the phone page's server while `remote.statusPage` is `tailnet`, on `remote.localPort`.
    private func updatePhoneServer(config: TenderConfig) {
        let wanted = config.remote.statusPage == .tailnet ? config.remote.localPort : nil
        guard wanted != phonePort else { return }
        phone?.stop()
        phone = nil
        phonePort = nil
        guard let port = wanted else {
            log("phone page stopped")
            return
        }
        let shared = self.shared
        let paths = self.paths
        let server = PhoneServer(paths: paths, owner: TailscaleServe().ownerLogin(),
                                 config: { shared.value.config }, facts: { shared.value.facts },
                                 onPushTest: { alert in await WebPushSender(paths: paths).send(alert) })
        do {
            try server.start(port: port)
            phone = server
            phonePort = port
            log("phone page listening on 127.0.0.1:\(port)")
        } catch {
            log("phone page couldn’t listen on 127.0.0.1:\(port): \(error)")
            phonePort = port // don't retry every tick; a config change retries
        }
    }

    public func runForever() -> Never {
        let stop = DispatchSemaphore(value: 0)
        var sources: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { stop.signal() }
            source.resume()
            sources.append(source)
        }
        log("tender-agent started (config: \(paths.configFile.path))")
        reportDowntime()
        withExtendedLifetime(sources) {
            while true {
                tick()
                if stop.wait(timeout: .now() + interval) == .success { break }
            }
        }
        power.release()
        log("tender-agent stopping; keep-awake released")
        exit(0)
    }

    private func reloadConfigIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: paths.configFile.path)
        let modified = attributes?[.modificationDate] as? Date
        guard config == nil || modified != configModified else { return }
        configModified = modified
        do {
            let loaded = try ConfigLoader.load(from: paths.configFile)
            if config != nil, loaded != config { log("config.yaml changed; reloaded") }
            config = loaded
            configError = nil
        } catch {
            // Keep running on the last good config; a half-saved file shouldn't wake the Mac up or let it sleep.
            let message = String(describing: error)
            if message != configError {
                log("config.yaml has a problem, keeping the previous settings: \(message)")
            }
            configError = message
        }
    }

    private func updateKeepAwake() -> AgentState.KeepAwake {
        guard let config, config.serverMode.keepAwake else {
            power.release()
            return .init(wanted: false, held: false, reason: "keepAwake is off in config.yaml")
        }
        let source = powerSource()
        if source.hasBattery, !source.onACPower {
            if power.isHeld { log("on battery; releasing keep-awake") }
            power.release()
            let percent = source.batteryPercent.map { " (\($0)%)" } ?? ""
            return .init(wanted: true, held: false, reason: "on battery\(percent); the Mac may sleep to save it")
        }
        let wasHeld = power.isHeld
        if power.hold(reason: "Tender server mode: keeping this Mac awake for its services") {
            if !wasHeld { log("keep-awake held") }
            return .init(wanted: true, held: true, reason: source.hasBattery ? "on power" : "server mode on")
        }
        return .init(wanted: true, held: false, reason: "macOS refused the power assertion")
    }

    // ISO8601DateFormatter is documented as thread-safe.
    nonisolated(unsafe) private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        formatter.timeZone = .current
        return formatter
    }()

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("\(Self.timestamp.string(from: Date())) \(message)\n".utf8))
    }
}

/// Crash-loop detection and likely causes only read files; this stands in where no launchd queries are wanted.
struct NoLaunchControl: LaunchControl {
    func info(_ label: String) -> LaunchJobInfo? { nil }
    func bootstrap(plist: URL, label: String) throws {}
    func bootout(_ label: String) throws {}
    func kickstart(_ label: String, kill: Bool) throws {}
}
