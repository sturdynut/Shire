import Foundation

public struct ShellResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Runs a program and captures its output. A protocol so tests can fake `launchctl` and the login shell.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) throws -> ShellResult
}

public extension CommandRunning {
    func run(_ executable: String, _ arguments: [String]) throws -> ShellResult {
        try run(executable, arguments, environment: nil, timeout: 30)
    }
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        // Drain both pipes concurrently so a chatty program can't fill one and deadlock.
        let collector = OutputCollector()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collector.set(data, isOut: isOut)
                group.leave()
            }
        }

        let deadline = DispatchTime.now() + timeout
        var timedOut = false
        if finished.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        // A background child of the program can keep the pipes open; don't wait on it forever.
        _ = group.wait(timeout: .now() + 3)
        let (stdout, stderr) = collector.strings()
        return ShellResult(status: process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func set(_ data: Data, isOut: Bool) {
        lock.withLock {
            if isOut { out = data } else { err = data }
        }
    }

    func strings() -> (String, String) {
        lock.withLock { (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self)) }
    }
}
