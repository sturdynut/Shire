import Foundation

/// What `launchctl print` says about a job.
public struct LaunchJobInfo: Equatable, Sendable {
    public var state: String?
    public var pid: Int?
    public var runs: Int?
    public var lastExitCode: Int?
    public var program: String?
    public var arguments: [String]

    public init(state: String? = nil, pid: Int? = nil, runs: Int? = nil, lastExitCode: Int? = nil, program: String? = nil, arguments: [String] = []) {
        self.state = state
        self.pid = pid
        self.runs = runs
        self.lastExitCode = lastExitCode
        self.program = program
        self.arguments = arguments
    }

    public var isRunning: Bool { state == "running" && pid != nil }

    /// Parses the top level of `launchctl print` output. Nested sections are skipped except `arguments`.
    public static func parse(_ output: String) -> LaunchJobInfo {
        var info = LaunchJobInfo()
        var depth = 0
        var inArguments = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("{") {
                depth += 1
                inArguments = depth == 2 && line.hasPrefix("arguments =")
                continue
            }
            if line == "}" {
                depth -= 1
                inArguments = false
                continue
            }
            if inArguments {
                if !line.isEmpty { info.arguments.append(line) }
                continue
            }
            guard depth == 1, let eq = line.range(of: " = ") else { continue }
            let key = String(line[..<eq.lowerBound])
            let value = String(line[eq.upperBound...])
            switch key {
            case "state": info.state = value
            case "pid": info.pid = Int(value)
            case "runs": info.runs = Int(value)
            case "last exit code": info.lastExitCode = Int(value.split(separator: ":").first.map(String.init) ?? value)
            case "program": info.program = value
            default: break
            }
        }
        return info
    }
}

public enum LaunchControlError: Error, CustomStringConvertible {
    case failed(action: String, label: String, detail: String)

    public var description: String {
        switch self {
        case .failed(let action, let label, let detail):
            return "launchctl \(action) \(label) failed: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

public protocol LaunchControl: Sendable {
    func info(_ label: String) -> LaunchJobInfo?
    func bootstrap(plist: URL, label: String) throws
    func bootout(_ label: String) throws
    func kickstart(_ label: String, kill: Bool) throws
}

public extension LaunchControl {
    func isLoaded(_ label: String) -> Bool { info(label) != nil }
}

/// Talks to launchd in the logged-in user's GUI domain (`gui/<uid>`).
public struct SystemLaunchControl: LaunchControl {
    public var runner: CommandRunning
    public var domain: String

    public init(runner: CommandRunning = SystemCommandRunner(), uid: uid_t = getuid()) {
        self.runner = runner
        self.domain = "gui/\(uid)"
    }

    public func info(_ label: String) -> LaunchJobInfo? {
        guard let result = try? runner.run("/bin/launchctl", ["print", "\(domain)/\(label)"]), result.status == 0 else { return nil }
        return LaunchJobInfo.parse(result.stdout)
    }

    public func bootstrap(plist: URL, label: String) throws {
        // Right after a bootout launchd can still be tearing the job down and answers “Input/output error”; retry briefly.
        var lastError = ""
        for attempt in 0..<10 {
            let result = try runner.run("/bin/launchctl", ["bootstrap", domain, plist.path])
            if result.status == 0 { return }
            lastError = result.stderr + result.stdout
            if attempt < 9 { Thread.sleep(forTimeInterval: 0.3) }
        }
        throw LaunchControlError.failed(action: "bootstrap", label: label, detail: lastError)
    }

    public func bootout(_ label: String) throws {
        let result = try runner.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        // 3 / 113: not loaded, which is what we wanted anyway.
        if result.status != 0, result.status != 3, result.status != 113, isLoaded(label) {
            throw LaunchControlError.failed(action: "bootout", label: label, detail: result.stderr + result.stdout)
        }
        for _ in 0..<25 where isLoaded(label) {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    public func kickstart(_ label: String, kill: Bool) throws {
        let args = ["kickstart"] + (kill ? ["-k"] : []) + ["\(domain)/\(label)"]
        let result = try runner.run("/bin/launchctl", args)
        if result.status != 0 {
            throw LaunchControlError.failed(action: "kickstart", label: label, detail: result.stderr + result.stdout)
        }
    }
}
