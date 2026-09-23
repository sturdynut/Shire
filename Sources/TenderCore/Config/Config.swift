import Foundation

/// The whole of `config.yaml`, with defaults filled in.
public struct TenderConfig: Equatable, Sendable {
    public var serverMode: ServerMode
    public var presets: Presets
    public var remote: RemoteSettings
    public var alerts: AlertSettings
    public var logs: LogSettings
    public var services: [String: ServiceConfig]

    public init(
        serverMode: ServerMode = ServerMode(),
        presets: Presets = Presets(),
        remote: RemoteSettings = RemoteSettings(),
        alerts: AlertSettings = AlertSettings(),
        logs: LogSettings = LogSettings(),
        services: [String: ServiceConfig] = [:]
    ) {
        self.serverMode = serverMode
        self.presets = presets
        self.remote = remote
        self.alerts = alerts
        self.logs = logs
        self.services = services
    }

    /// Services that Tender generates LaunchAgents for.
    public var managedServiceNames: [String] {
        services.filter { !$0.value.isExternal }.keys.sorted()
    }
}

public struct ServerMode: Equatable, Sendable, Decodable {
    public var keepAwake: Bool

    public init(keepAwake: Bool = false) {
        self.keepAwake = keepAwake
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? false
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case keepAwake }
}

public struct Presets: Equatable, Sendable, Decodable {
    public var tailscale: TailscalePreset

    public init(tailscale: TailscalePreset = TailscalePreset()) {
        self.tailscale = tailscale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tailscale = try c.decodeIfPresent(TailscalePreset.self, forKey: .tailscale) ?? TailscalePreset()
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case tailscale }
}

public struct TailscalePreset: Equatable, Sendable, Decodable {
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case enabled }
}

public struct RemoteSettings: Equatable, Sendable, Decodable {
    public enum StatusPage: String, Sendable, Decodable { case tailnet, off }
    public enum Actions: String, Sendable, Decodable {
        case restart
        case readOnly = "read-only"
    }

    public var statusPage: StatusPage
    public var actions: Actions
    /// HTTPS port on your tailnet (`tailscale serve --https=<port>`).
    public var port: Int
    /// Where tender-agent listens on this Mac, behind tailscale serve. Only 127.0.0.1.
    public var localPort: Int

    public init(statusPage: StatusPage = .off, actions: Actions = .restart, port: Int = 7777, localPort: Int = 7780) {
        self.statusPage = statusPage
        self.actions = actions
        self.port = port
        self.localPort = localPort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statusPage = try c.decodeIfPresent(StatusPage.self, forKey: .statusPage) ?? .off
        actions = try c.decodeIfPresent(Actions.self, forKey: .actions) ?? .restart
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 7777
        localPort = try c.decodeIfPresent(Int.self, forKey: .localPort) ?? 7780
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case statusPage, actions, port, localPort }
}

public struct AlertSettings: Equatable, Sendable, Decodable {
    public var macos: Bool
    public var phone: Bool
    public var crashLoop: CrashLoopRule
    public var unhealthyFor: DurationValue

    public init(macos: Bool = true, phone: Bool = false, crashLoop: CrashLoopRule = .default, unhealthyFor: DurationValue = DurationValue(seconds: 120)) {
        self.macos = macos
        self.phone = phone
        self.crashLoop = crashLoop
        self.unhealthyFor = unhealthyFor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        macos = try c.decodeIfPresent(Bool.self, forKey: .macos) ?? true
        phone = try c.decodeIfPresent(Bool.self, forKey: .phone) ?? false
        crashLoop = try c.decodeIfPresent(CrashLoopRule.self, forKey: .crashLoop) ?? .default
        unhealthyFor = try c.decodeIfPresent(DurationValue.self, forKey: .unhealthyFor) ?? DurationValue(seconds: 120)
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case macos, phone, crashLoop, unhealthyFor }
}

public struct LogSettings: Equatable, Sendable, Decodable {
    public var maxSize: ByteSize
    public var keep: Int

    public init(maxSize: ByteSize = ByteSize(bytes: 10 << 20), keep: Int = 3) {
        self.maxSize = maxSize
        self.keep = keep
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxSize = try c.decodeIfPresent(ByteSize.self, forKey: .maxSize) ?? ByteSize(bytes: 10 << 20)
        keep = try c.decodeIfPresent(Int.self, forKey: .keep) ?? 3
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case maxSize, keep }
}

public enum RestartPolicy: String, Equatable, Sendable, Decodable {
    case always
    case onFailure = "on-failure"
    case never
}

public struct ServiceConfig: Equatable, Sendable, Decodable {
    public var command: String?
    public var args: [String]
    public var cwd: String?
    public var env: [String: String]
    public var envFile: String?
    public var build: String?
    public var restart: RestartPolicy
    public var dependsOn: [String]
    public var health: HealthCheckConfig?
    public var serve: Int?
    /// Label of an existing launchd job that Tender watches but doesn't manage.
    public var external: String?
    /// When something already answers the health check at start (an app you opened yourself), watch it instead of
    /// starting a second copy. Meant for single-instance GUI apps like TradingView.
    public var adoptRunning: Bool

    public var isExternal: Bool { external != nil }

    public init(
        command: String? = nil,
        args: [String] = [],
        cwd: String? = nil,
        env: [String: String] = [:],
        envFile: String? = nil,
        build: String? = nil,
        restart: RestartPolicy = .always,
        dependsOn: [String] = [],
        health: HealthCheckConfig? = nil,
        serve: Int? = nil,
        external: String? = nil,
        adoptRunning: Bool = false
    ) {
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.envFile = envFile
        self.build = build
        self.restart = restart
        self.dependsOn = dependsOn
        self.health = health
        self.serve = serve
        self.external = external
        self.adoptRunning = adoptRunning
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        envFile = try c.decodeIfPresent(String.self, forKey: .envFile)
        build = try c.decodeIfPresent(String.self, forKey: .build)
        restart = try c.decodeIfPresent(RestartPolicy.self, forKey: .restart) ?? .always
        dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        health = try c.decodeIfPresent(HealthCheckConfig.self, forKey: .health)
        serve = try c.decodeIfPresent(Int.self, forKey: .serve)
        external = try c.decodeIfPresent(String.self, forKey: .external)
        adoptRunning = try c.decodeIfPresent(Bool.self, forKey: .adoptRunning) ?? false
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case command, args, cwd, env, envFile, build, restart, dependsOn, health, serve, external, adoptRunning
    }
}

public struct HealthCheckConfig: Equatable, Sendable, Decodable {
    public enum Kind: String, Sendable, Decodable { case http, tcp }

    public var type: Kind
    public var url: String?
    public var host: String
    public var port: Int?
    public var interval: DurationValue
    public var timeout: DurationValue

    public init(type: Kind, url: String? = nil, host: String = "127.0.0.1", port: Int? = nil,
                interval: DurationValue = DurationValue(seconds: 30), timeout: DurationValue = DurationValue(seconds: 3)) {
        self.type = type
        self.url = url
        self.host = host
        self.port = port
        self.interval = interval
        self.timeout = timeout
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(Kind.self, forKey: .type)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        interval = try c.decodeIfPresent(DurationValue.self, forKey: .interval) ?? DurationValue(seconds: 30)
        timeout = try c.decodeIfPresent(DurationValue.self, forKey: .timeout) ?? DurationValue(seconds: 3)
    }

    /// The host and port this check connects to, for dependency waits and port-clash checks.
    public var endpoint: HostPort? {
        switch type {
        case .tcp:
            guard let port else { return nil }
            return HostPort(host: host, port: port)
        case .http:
            guard let url, let components = URLComponents(string: url), let host = components.host else { return nil }
            let port = components.port ?? (components.scheme == "https" ? 443 : 80)
            return HostPort(host: host, port: port)
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case type, url, host, port, interval, timeout }
}

public struct HostPort: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Parses `host:port`.
    public init?(parsing text: String) {
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else { return nil }
        let host = String(text[..<colon])
        guard !host.isEmpty else { return nil }
        self.host = host
        self.port = port
    }

    public var description: String { "\(host):\(port)" }
}
