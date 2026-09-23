import Foundation

public struct RunnerOptions: Equatable, Sendable {
    public var name: String
    public var logDir: URL
    public var maxLogSize: Int
    public var keepLogs: Int
    public var eventsFile: URL?
    public var envFile: URL?
    public var waitFor: [HostPort]
    public var waitTimeout: TimeInterval
    /// If this endpoint already answers at start, watch that copy instead of starting another.
    public var adopt: HostPort?
    public var adoptPollInterval: TimeInterval
    public var command: String
    public var arguments: [String]

    public init(name: String, logDir: URL, maxLogSize: Int, keepLogs: Int, eventsFile: URL?, envFile: URL?,
                waitFor: [HostPort], waitTimeout: TimeInterval = 120, adopt: HostPort? = nil, adoptPollInterval: TimeInterval = 5,
                command: String, arguments: [String]) {
        self.name = name
        self.logDir = logDir
        self.maxLogSize = maxLogSize
        self.keepLogs = keepLogs
        self.eventsFile = eventsFile
        self.envFile = envFile
        self.waitFor = waitFor
        self.waitTimeout = waitTimeout
        self.adopt = adopt
        self.adoptPollInterval = adoptPollInterval
        self.command = command
        self.arguments = arguments
    }
}

/// `tender run`: what launchd actually starts. It waits for dependencies, loads the env file, runs the real
/// command with its output captured into rotating logs, forwards stop signals, and exits with the command's status
/// so launchd's restart policy still applies.
public final class ServiceRunner: @unchecked Sendable {
    public static let exitCommandNotFound: Int32 = 127
    public static let exitNotExecutable: Int32 = 126
    public static let exitDependencyTimeout: Int32 = 75 // EX_TEMPFAIL
    /// An adoptable app exited at once without opening its port: it handed off to a copy that's already open.
    public static let exitHandedOff: Int32 = 69 // EX_UNAVAILABLE

    private let options: RunnerOptions
    private let stdoutLog: RotatingLog
    private let stderrLog: RotatingLog
    private let events: EventLog?
    private let lock = NSLock()
    private var child: Process?
    private var stopRequested = false

    public init(options: RunnerOptions) throws {
        self.options = options
        stdoutLog = try RotatingLog(url: options.logDir.appending(path: "\(options.name).stdout.log"), maxBytes: options.maxLogSize, keep: options.keepLogs)
        stderrLog = try RotatingLog(url: options.logDir.appending(path: "\(options.name).stderr.log"), maxBytes: options.maxLogSize, keep: options.keepLogs)
        events = options.eventsFile.map { EventLog(url: $0) }
    }

    public func run() -> Int32 {
        events?.append(ServiceEvent(time: Date(), kind: .start, command: options.command))
        let code = runChild()
        events?.append(ServiceEvent(time: Date(), kind: .exit, code: code, command: options.command))
        return code
    }

    private func runChild() -> Int32 {
        say("starting \(options.name)")
        let signals = installSignalForwarding()
        defer {
            signals.forEach { $0.cancel() }
            [SIGTERM, SIGINT, SIGHUP].forEach { signal($0, SIG_DFL) }
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: options.command) {
            var message = "no such file: \(options.command)"
            if let manager = CommandResolver.versionManager(forPath: options.command) {
                message += " (\(manager) switched versions since the last apply; run `tender apply` to re-resolve)"
            }
            say(message, error: true)
            return Self.exitCommandNotFound
        }
        if !fm.isExecutableFile(atPath: options.command) {
            say("not executable: \(options.command)", error: true)
            return Self.exitNotExecutable
        }

        for endpoint in options.waitFor {
            if !waitUntilReachable(endpoint) {
                if stopRequestedSnapshot() { return 0 }
                say("gave up waiting for \(endpoint) after \(DurationValue(seconds: options.waitTimeout)); launchd will try again", error: true)
                return Self.exitDependencyTimeout
            }
        }

        if let adopt = options.adopt, HealthProbe.tcpConnect(adopt, timeout: 1) {
            say("\(options.name) is already running (\(adopt) answers); watching it instead of starting a second copy")
            while !stopRequestedSnapshot(), HealthProbe.tcpConnect(adopt, timeout: 1) {
                sleepUnlessStopped(options.adoptPollInterval)
            }
            if stopRequestedSnapshot() {
                say("stopped watching; the copy you opened was left running")
                return 0
            }
            say("the running copy went away; starting \(options.name)")
        }

        var environment = ProcessInfo.processInfo.environment
        if let envFile = options.envFile {
            do {
                environment.merge(try EnvFile.load(envFile)) { _, fromFile in fromFile }
            } catch {
                say("couldn’t read env file \(envFile.path): \(error.localizedDescription)", error: true)
                return 78 // EX_CONFIG
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: options.command)
        process.arguments = options.arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        out.fileHandleForReading.readabilityHandler = { [stdoutLog] handle in stdoutLog.write(handle.availableData) }
        err.fileHandleForReading.readabilityHandler = { [stderrLog] handle in stderrLog.write(handle.availableData) }

        say("exec \(([options.command] + options.arguments).joined(separator: " "))")
        let started = Date()
        do {
            try lock.withLock {
                if stopRequested { throw CancellationError() }
                try process.run()
                child = process
            }
        } catch is CancellationError {
            return 0
        } catch {
            say("couldn’t start \(options.command): \(error.localizedDescription)", error: true)
            return Self.exitNotExecutable
        }
        process.waitUntilExit()

        // Let the readability handlers drain whatever is left in the pipes.
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        stdoutLog.write(out.fileHandleForReading.readDataToEndOfFileIfPossible())
        stderrLog.write(err.fileHandleForReading.readDataToEndOfFileIfPossible())

        let runtime = DurationValue(seconds: (Date().timeIntervalSince(started) * 100).rounded() / 100)
        let code: Int32
        switch process.terminationReason {
        case .uncaughtSignal:
            code = 128 + process.terminationStatus
            say("stopped by signal \(process.terminationStatus) after \(runtime)", error: !stopRequestedSnapshot())
        default:
            code = process.terminationStatus
            if code == 0, let adopt = options.adopt, runtime.seconds < 5, !stopRequestedSnapshot(), !HealthProbe.tcpConnect(adopt, timeout: 1) {
                say("\(options.name) exited right away without opening \(adopt). It’s probably already open without the options Tender starts it with; quit it once and Tender will start it properly.", error: true)
                return Self.exitHandedOff
            }
            say("exited \(code) after \(runtime)", error: code != 0)
        }
        return stopRequestedSnapshot() && code == 128 + SIGTERM ? 0 : code
    }

    private func stopRequestedSnapshot() -> Bool {
        lock.withLock { stopRequested }
    }

    private func sleepUnlessStopped(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !stopRequestedSnapshot() {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func waitUntilReachable(_ endpoint: HostPort) -> Bool {
        let deadline = Date().addingTimeInterval(options.waitTimeout)
        var announced = false
        while Date() < deadline {
            if stopRequestedSnapshot() { return false }
            if HealthProbe.tcpConnect(endpoint, timeout: 1) { return true }
            if !announced {
                say("waiting for \(endpoint)")
                announced = true
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    /// launchd stops a job with SIGTERM, then SIGKILL after its exit timeout. Pass SIGTERM on to the command.
    private func installSignalForwarding() -> [DispatchSourceSignal] {
        [SIGTERM, SIGINT, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let child = self.lock.withLock { () -> Process? in
                    self.stopRequested = true
                    return self.child
                }
                if let child, child.isRunning {
                    kill(child.processIdentifier, number)
                }
            }
            source.resume()
            return source
        }
    }

    // ISO8601DateFormatter is documented as thread-safe.
    nonisolated(unsafe) private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        formatter.timeZone = .current
        return formatter
    }()

    private func say(_ message: String, error: Bool = false) {
        let line = "\(Self.timestamp.string(from: Date())) tender: \(message)"
        (error ? stderrLog : stdoutLog).write(line: line)
    }
}

private extension FileHandle {
    /// Reads whatever is already buffered without blocking. A grandchild that outlives the command
    /// (a server `pnpm` started, say) can keep the pipe open, so waiting for end-of-file could hang forever.
    func readDataToEndOfFileIfPossible() -> Data {
        let fd = fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
