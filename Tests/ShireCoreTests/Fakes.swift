import Foundation
@testable import ShireCore

/// Records launchctl calls and keeps a set of "loaded" labels.
final class FakeLaunchControl: LaunchControl, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: [String: LaunchJobInfo] = [:]
    private(set) var calls: [String] = []

    init(loaded: [String: LaunchJobInfo] = [:]) {
        self.loaded = loaded
    }

    func setInfo(_ label: String, _ info: LaunchJobInfo?) {
        lock.withLock { loaded[label] = info }
    }

    func info(_ label: String) -> LaunchJobInfo? {
        lock.withLock { loaded[label] }
    }

    func bootstrap(plist: URL, label: String) throws {
        lock.withLock {
            calls.append("bootstrap \(label)")
            loaded[label] = LaunchJobInfo(state: "running", pid: 42, runs: 1)
        }
    }

    func bootout(_ label: String) throws {
        lock.withLock {
            calls.append("bootout \(label)")
            loaded[label] = nil
        }
    }

    func kickstart(_ label: String, kill: Bool) throws {
        lock.withLock { calls.append("kickstart\(kill ? " -k" : "") \(label)") }
    }
}

struct FakeBuilder: ServiceBuilding {
    var succeeds: Bool
    let log = BuildLog()

    func build(name: String, command: String, cwd: String?, environment: [String: String]) -> Bool {
        log.append("\(name): \(command)")
        return succeeds
    }
}

final class BuildLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
}

struct FakeRunner: CommandRunning {
    var stdout: String
    var status: Int32 = 0

    func run(_ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) throws -> ShellResult {
        ShellResult(status: status, stdout: stdout, stderr: "")
    }
}

/// A throwaway home folder, removed when the test ends.
final class TempHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "shire-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var paths: ShirePaths { ShirePaths(home: url) }

    @discardableResult
    func makeDirectory(_ relative: String) throws -> URL {
        let dir = url.appending(path: relative)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> URL {
        let file = url.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

/// The config from PLAN.md, used across tests.
let planConfigYAML = """
serverMode: { keepAwake: true }
presets: { tailscale: { enabled: true } }
remote: { statusPage: tailnet, actions: restart }

alerts:
  macos: true
  phone: true
  crashLoop: 3 in 5m
  unhealthyFor: 2m

logs: { maxSize: 10MB, keep: 3 }

services:
  postgres:
    external: homebrew.mxcl.postgresql@16
    health: { type: tcp, port: 5432 }

  bagend-api:
    command: node
    args: [dist/index.js]
    build: pnpm build
    cwd: ~/Code/bagend/server
    envFile: .env.demo
    dependsOn: [postgres]
    health: { type: tcp, port: 3001 }

  bagend-web:
    command: pnpm
    args: [preview, --port, "5174"]
    build: pnpm build
    cwd: ~/Code/bagend/web
    serve: 443
    dependsOn: [bagend-api]
    health: { type: http, url: http://localhost:5174 }

  redbook:
    command: /Applications/RedBook.app/Contents/MacOS/RedBook
    args: [--remote-debugging-port=9222]
    health: { type: tcp, port: 9222 }
"""

let nvm22_14 = "/Users/me/.nvm/versions/node/v22.14.0/bin"

func planResolution() -> ResolvedEnvironment {
    ResolvedEnvironment(
        commands: [
            "node": CommandResolution(command: "node", path: "\(nvm22_14)/node"),
            "pnpm": CommandResolution(command: "pnpm", path: "\(nvm22_14)/pnpm"),
            "/Applications/RedBook.app/Contents/MacOS/RedBook": CommandResolution(
                command: "/Applications/RedBook.app/Contents/MacOS/RedBook",
                path: "/Applications/RedBook.app/Contents/MacOS/RedBook"),
        ],
        loginPath: "\(nvm22_14):/opt/homebrew/bin:/usr/bin:/bin"
    )
}

final class FakeNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var delivered: [AlertMessage] = []

    func deliver(_ alert: AlertMessage) { lock.withLock { delivered.append(alert) } }
    var titles: [String] { lock.withLock { delivered.map(\.title) } }
}
