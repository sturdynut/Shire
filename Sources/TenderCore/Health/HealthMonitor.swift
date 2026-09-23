import Foundation

/// A service's health as tender-agent has seen it over time, not just the last check.
public struct ServiceHealth: Codable, Equatable, Sendable {
    public var healthy: Bool
    public var detail: String
    /// When the service entered its current healthy/unhealthy state.
    public var since: Date
    public var lastChecked: Date
    public var consecutiveFailures: Int

    public init(healthy: Bool, detail: String, since: Date, lastChecked: Date, consecutiveFailures: Int) {
        self.healthy = healthy
        self.detail = detail
        self.since = since
        self.lastChecked = lastChecked
        self.consecutiveFailures = consecutiveFailures
    }

    /// How long it has been unhealthy, or nil when healthy.
    public func unhealthyFor(now: Date) -> TimeInterval? {
        healthy ? nil : now.timeIntervalSince(since)
    }
}

/// Runs each service's health check on its own interval and keeps the history that alert rules need.
public final class HealthMonitor {
    public typealias Probe = @Sendable (HealthCheckConfig) -> HealthResult

    public private(set) var states: [String: ServiceHealth]
    private let probe: Probe

    /// A failing service is rechecked this often (or at its own interval, if shorter), so recovery shows up within
    /// seconds instead of waiting out a long healthy-interval.
    public static let failingRecheck: TimeInterval = 5

    public init(states: [String: ServiceHealth] = [:], probe: @escaping Probe = HealthProbe.checkBlocking) {
        self.states = states
        self.probe = probe
    }

    /// Checks every service whose interval has passed, concurrently, and returns the updated states.
    @discardableResult
    public func runDueChecks(config: TenderConfig, now: Date = Date()) -> [String: ServiceHealth] {
        // Forget services that left the config or lost their health check.
        states = states.filter { config.services[$0.key]?.health != nil }

        let due = config.services.compactMap { name, service -> (String, HealthCheckConfig)? in
            guard let check = service.health else { return nil }
            if let state = states[name] {
                let every = state.healthy ? check.interval.seconds : min(check.interval.seconds, Self.failingRecheck)
                if now.timeIntervalSince(state.lastChecked) < every { return nil }
            }
            return (name, check)
        }
        guard !due.isEmpty else { return states }

        let results = ResultBox()
        let group = DispatchGroup()
        for (name, check) in due {
            group.enter()
            DispatchQueue.global().async { [probe] in
                results.set(name, probe(check))
                group.leave()
            }
        }
        group.wait()

        for (name, result) in results.all {
            states[name] = Self.next(states[name], result: result, now: now)
        }
        return states
    }

    static func next(_ previous: ServiceHealth?, result: HealthResult, now: Date) -> ServiceHealth {
        let healthy = result.isHealthy
        let changed = previous?.healthy != healthy
        return ServiceHealth(
            healthy: healthy,
            detail: result.detail,
            since: changed ? now : previous!.since,
            lastChecked: now,
            consecutiveFailures: healthy ? 0 : (previous?.consecutiveFailures ?? 0) + 1
        )
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: HealthResult] = [:]

    func set(_ name: String, _ result: HealthResult) { lock.withLock { results[name] = result } }
    var all: [String: HealthResult] { lock.withLock { results } }
}

extension HealthProbe {
    /// For tender-agent's synchronous loop.
    public static func checkBlocking(_ config: HealthCheckConfig) -> HealthResult {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.set("result", await check(config))
            done.signal()
        }
        // The check has its own timeout; this is a backstop.
        if done.wait(timeout: .now() + config.timeout.seconds + 5) == .timedOut {
            return .unhealthy(detail: "health check hung")
        }
        return box.all["result"] ?? .unhealthy(detail: "health check failed")
    }
}
