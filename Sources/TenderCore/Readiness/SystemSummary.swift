import Foundation

/// The SYSTEM rows under `tender status`: tender-agent, keep-awake, Tailscale and the readiness count.
public struct SystemSummary: Sendable {
    public struct Row: Equatable, Sendable {
        public var name: String
        public var value: String
        public var level: ReadinessCheck.Level
    }

    public var rows: [Row] = []
    /// Row names that count as needing attention in the overall summary.
    public var problems: [String] = []

    public init(facts: SystemFacts, config: TenderConfig, now: Date = Date()) {
        let fresh = facts.agentState.flatMap { $0.isFresh(now: now) ? $0 : nil }
        if let state = fresh {
            add("tender-agent", "running · pid \(state.pid)", .ok)
        } else if facts.agentLoaded {
            add("tender-agent", "not responding", .warn, problem: true)
        } else {
            add("tender-agent", "not installed · run `tender apply`", .warn, problem: true)
        }

        if !config.serverMode.keepAwake {
            add("keep-awake", "off in config.yaml", .info)
        } else if let state = fresh {
            if state.keepAwake.held {
                add("keep-awake", "active · \(state.keepAwake.reason)", .ok)
            } else {
                add("keep-awake", "released · \(state.keepAwake.reason)", .warn, problem: true)
            }
        } else {
            add("keep-awake", "inactive · tender-agent isn’t running", .warn, problem: true)
        }

        if config.presets.tailscale.enabled {
            switch facts.tailscale {
            case .connected(let host, _, let ip):
                add("tailscale", "connected · \(host)\(ip.map { " · \($0)" } ?? "")", .ok)
            case .notConnected(let backend):
                add("tailscale", "not connected · \(backend)", .warn, problem: true)
            case .daemonNotRunning:
                add("tailscale", "not running", .warn, problem: true)
            case .notInstalled:
                add("tailscale", "not installed", .warn, problem: true)
            }
        }

        let warnings = Readiness.warnings(Readiness.evaluate(facts, config: config, now: now)).count
        if warnings == 0 {
            add("readiness", "ready", .ok)
        } else {
            add("readiness", "\(warnings) warning\(warnings == 1 ? "" : "s") · run `tender doctor`", .warn)
        }
    }

    private mutating func add(_ name: String, _ value: String, _ level: ReadinessCheck.Level, problem: Bool = false) {
        rows.append(Row(name: name, value: value, level: level))
        if problem { problems.append(name) }
    }
}
