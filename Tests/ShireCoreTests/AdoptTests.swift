import Foundation
import Testing
@testable import ShireCore

/// A real listening socket on 127.0.0.1, standing in for "an app you opened yourself".
final class TestListener {
    let port: Int
    private var fd: Int32

    init() throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(s, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &length) }
        }
        fd = s
        port = Int(UInt16(bigEndian: actual.sin_port))
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    deinit { close() }
}

@Suite("Adopting a running copy", .serialized)
struct AdoptTests {
    func options(_ home: TempHome, _ command: String, _ args: [String], adopt: HostPort) -> RunnerOptions {
        RunnerOptions(name: "redbook", logDir: home.url.appending(path: "logs"), maxLogSize: 1 << 20, keepLogs: 1,
                      eventsFile: nil, envFile: nil, waitFor: [], adopt: adopt, adoptPollInterval: 0.2,
                      command: command, arguments: args)
    }

    func log(_ home: TempHome, _ stream: String) throws -> String {
        try String(contentsOf: home.url.appending(path: "logs/redbook.\(stream).log"), encoding: .utf8)
    }

    @Test func watchesTheOpenCopyThenStartsItsOwnWhenItGoesAway() throws {
        let home = try TempHome()
        let listener = try TestListener()
        let endpoint = HostPort(host: "127.0.0.1", port: listener.port)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { listener.close() }

        let runner = try ServiceRunner(options: options(home, "/bin/sh", ["-c", "echo launched"], adopt: endpoint))
        let started = Date()
        _ = runner.run()
        let stdout = try log(home, "stdout")
        #expect(stdout.contains("already running (\(endpoint) answers)"))
        #expect(stdout.contains("the running copy went away"))
        #expect(stdout.contains("launched"))
        #expect(Date().timeIntervalSince(started) >= 0.8) // it waited while the copy was open
    }

    @Test func appThatHandsOffToAnOpenCopyIsNamed() throws {
        let home = try TempHome()
        // Nothing listens here, and the "app" exits at once with success, like a second Electron instance.
        let runner = try ServiceRunner(options: options(home, "/usr/bin/true", [], adopt: HostPort(host: "127.0.0.1", port: 1)))
        #expect(runner.run() == ServiceRunner.exitHandedOff)
        #expect(try log(home, "stderr").contains("exited right away without opening 127.0.0.1:1"))
    }

    @Test func likelyCauseForAHandOff() throws {
        let home = try TempHome()
        let inspector = StatusInspector(paths: home.paths, launchControl: FakeLaunchControl(), crashLoop: .default)
        let cause = inspector.likelyCause(name: "redbook", service: ServiceConfig(command: "/x"),
                                          state: .crashLooping(lastExit: 69, exits: 3, window: DurationValue(seconds: 300)), dependencyHealth: [:])
        #expect(cause?.hasPrefix("redbook is already open without the options Shire starts it with") == true)
    }

    @Test func plistAndValidation() throws {
        let config = try ConfigLoader.parse("""
        services:
          redbook:
            command: /Applications/RedBook.app/Contents/MacOS/RedBook
            args: [--remote-debugging-port=9222]
            adoptRunning: true
            health: { type: tcp, port: 9222 }
          bad: { command: /bin/echo, adoptRunning: true }
        """)
        let path = "/Applications/RedBook.app/Contents/MacOS/RedBook"
        let resolved = ResolvedEnvironment(commands: [path: CommandResolution(command: path, path: path), "/bin/echo": CommandResolution(command: "/bin/echo", path: "/bin/echo")], loginPath: "")
        let plist = Reconciler(paths: TestPaths.home, launchControl: FakeLaunchControl())
            .desiredPlists(config: config, resolved: resolved, shireExecutable: "/u")["redbook"]!
        let args = try #require(plist["ProgramArguments"] as? [String])
        #expect(args[args.firstIndex(of: "--adopt")! + 1] == "127.0.0.1:9222")

        let issues = Validator(home: "/Users/me", directoryExists: { _ in true }, fileExists: { _ in true }).validate(config)
        #expect(issues.contains { $0.service == "bad" && $0.message.contains("“adoptRunning” needs a health check") })
    }
}

enum TestPaths {
    static let home = ShirePaths(home: URL(fileURLWithPath: "/Users/me"))
}
