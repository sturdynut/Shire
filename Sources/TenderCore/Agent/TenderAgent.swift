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

    public init(pid: Int32, startedAt: Date, updatedAt: Date, configPath: String, configError: String?, keepAwake: KeepAwake) {
        self.pid = pid
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.configPath = configPath
        self.configError = configError
        self.keepAwake = keepAwake
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

/// tender-agent: the always-running part of Tender. Phase 2 owns keep-awake; health checks and alerts join it in Phase 3.
/// It re-reads config.yaml when the file changes, so editing `keepAwake` takes effect within one tick.
public final class TenderAgent {
    public let paths: TenderPaths
    public let interval: TimeInterval
    private let power: PowerAsserting
    private let powerSource: () -> PowerInfo
    private let startedAt: Date

    private var config: TenderConfig?
    private var configError: String?
    private var configModified: Date?

    public init(paths: TenderPaths, interval: TimeInterval = 5, power: PowerAsserting = PowerAssertion(),
                powerSource: @escaping () -> PowerInfo = PowerInfo.current, now: Date = Date()) {
        self.paths = paths
        self.interval = interval
        self.power = power
        self.powerSource = powerSource
        self.startedAt = now
    }

    /// One pass: reload config if it changed, decide keep-awake, record state.
    @discardableResult
    public func tick(now: Date = Date()) -> AgentState {
        reloadConfigIfNeeded()
        let keepAwake = updateKeepAwake()
        let state = AgentState(
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: startedAt,
            updatedAt: now,
            configPath: paths.configFile.path,
            configError: configError,
            keepAwake: keepAwake
        )
        try? state.write(to: paths.agentStateFile)
        return state
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
