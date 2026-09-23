import Foundation

/// Something Tender has already told you about. One alert opens it, at most one recovery message closes it.
public struct Incident: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case crashLoop, unhealthy, readiness }

    public var key: String
    public var kind: Kind
    public var service: String?
    public var openedAt: Date
    public var title: String

    public init(key: String, kind: Kind, service: String?, openedAt: Date, title: String) {
        self.key = key
        self.kind = kind
        self.service = service
        self.openedAt = openedAt
        self.title = title
    }
}

public struct AlertMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case problem, recovery, info }

    public var time: Date
    public var kind: Kind
    public var title: String
    public var body: String
    public var service: String?

    public init(time: Date, kind: Kind, title: String, body: String, service: String? = nil) {
        self.time = time
        self.kind = kind
        self.title = title
        self.body = body
        self.service = service
    }
}

public struct IncidentState: Codable, Equatable, Sendable {
    public var open: [String: Incident]

    public init(open: [String: Incident] = [:]) {
        self.open = open
    }

    public static func read(from url: URL) -> IncidentState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONCoding.decoder.decode(IncidentState.self, from: data) else { return IncidentState() }
        return state
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// What tender-agent saw for one service on this tick.
public struct ServiceObservation: Equatable, Sendable {
    public var crashLoop: ProcessState?
    public var cause: String?
    public var health: ServiceHealth?

    public init(crashLoop: ProcessState? = nil, cause: String? = nil, health: ServiceHealth? = nil) {
        self.crashLoop = crashLoop
        self.cause = cause
        self.health = health
    }
}

/// Turns observations into incidents and alerts. Pure, so every rule is testable:
/// - a crash loop alerts once, with the likely cause;
/// - a failing health check alerts only after `alerts.unhealthyFor`, and not on top of a crash-loop alert;
/// - a new readiness warning alerts once;
/// - when a service is fine again, its incidents close with one "healthy again" message.
public enum IncidentEngine {
    public static func evaluate(previous: IncidentState, services: [String: ServiceObservation], readinessWarnings: [ReadinessCheck]?,
                                config: TenderConfig, now: Date) -> (IncidentState, [AlertMessage]) {
        var state = previous
        var alerts: [AlertMessage] = []

        // Services that left the config: close quietly.
        for (key, incident) in state.open where incident.service != nil && config.services[incident.service!] == nil {
            state.open[key] = nil
        }

        for name in services.keys.sorted() {
            let observation = services[name]!
            let crashKey = "crash-loop:\(name)", unhealthyKey = "unhealthy:\(name)"

            if case .crashLooping(let code, let exits, let window)? = observation.crashLoop {
                if state.open[crashKey] == nil {
                    let title = "\(name) is crash-looping"
                    state.open[crashKey] = Incident(key: crashKey, kind: .crashLoop, service: name, openedAt: now, title: title)
                    var body = "Exit \(code), \(exits) restarts in \(window)."
                    if let cause = observation.cause { body += " " + sentence(cause) }
                    alerts.append(AlertMessage(time: now, kind: .problem, title: title, body: body, service: name))
                }
                continue
            }

            if let health = observation.health, let down = health.unhealthyFor(now: now) {
                if down >= config.alerts.unhealthyFor.seconds, state.open[unhealthyKey] == nil, state.open[crashKey] == nil {
                    let title = "\(name) is unhealthy"
                    state.open[unhealthyKey] = Incident(key: unhealthyKey, kind: .unhealthy, service: name, openedAt: health.since, title: title)
                    alerts.append(AlertMessage(time: now, kind: .problem, title: title,
                                               body: "\(sentence(health.detail)) Failing for \(Readiness.describe(down)).", service: name))
                }
                if let crash = state.open[crashKey] {
                    // The crash loop ended but it's still unhealthy: same incident, already reported. Stay quiet until it recovers.
                    state.open[crashKey] = nil
                    state.open[unhealthyKey] = Incident(key: unhealthyKey, kind: .unhealthy, service: name, openedAt: crash.openedAt, title: crash.title)
                }
                continue
            }

            // Not looping, and healthy (or no health check): close anything open.
            let closing = [crashKey, unhealthyKey].compactMap { state.open[$0] }
            if let first = closing.map(\.openedAt).min() {
                closing.forEach { state.open[$0.key] = nil }
                alerts.append(AlertMessage(time: now, kind: .recovery, title: "\(name) is healthy again",
                                           body: "Back after \(Readiness.describe(now.timeIntervalSince(first))).", service: name))
            }
        }

        if let warnings = readinessWarnings {
            let current = Set(warnings.map { "readiness:\($0.id)" })
            for check in warnings where state.open["readiness:\(check.id)"] == nil {
                let key = "readiness:\(check.id)"
                state.open[key] = Incident(key: key, kind: .readiness, service: nil, openedAt: now, title: check.title)
                alerts.append(AlertMessage(time: now, kind: .problem, title: check.title, body: check.fix ?? check.detail))
            }
            for key in state.open.keys where key.hasPrefix("readiness:") && !current.contains(key) {
                state.open[key] = nil
            }
        }
        return (state, alerts)
    }

    /// The "services were down" report, made when tender-agent starts and finds a gap since it last reported.
    public static func downtime(previousHeartbeat: Date?, bootTime: Date?, agentStart: Date, minimumGap: TimeInterval = 120) -> AlertMessage? {
        guard let heartbeat = previousHeartbeat else { return nil }
        let gap = agentStart.timeIntervalSince(heartbeat)
        guard gap >= minimumGap else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        let since = formatter.string(from: heartbeat)
        if let boot = bootTime, boot > heartbeat {
            return AlertMessage(time: agentStart, kind: .info, title: "This Mac restarted",
                                body: "Services were down for about \(Readiness.describe(gap)), since \(since). They’re starting again now.")
        }
        return AlertMessage(time: agentStart, kind: .info, title: "Tender was stopped",
                            body: "tender-agent wasn’t running for about \(Readiness.describe(gap)), since \(since). Services it watches weren’t being checked.")
    }

    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        let capitalized = first.uppercased() + text.dropFirst()
        return capitalized.hasSuffix(".") ? capitalized : capitalized + "."
    }
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
