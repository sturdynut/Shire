import Foundation

public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }

    public var severity: Severity
    public var service: String?
    public var message: String

    public init(_ severity: Severity, _ service: String?, _ message: String) {
        self.severity = severity
        self.service = service
        self.message = message
    }

    public var description: String {
        let prefix = service.map { "\($0): " } ?? ""
        return prefix + message
    }
}

/// Checks a parsed config against the things that would make launchd fail quietly.
public struct Validator: Sendable {
    public var home: String
    public var directoryExists: @Sendable (String) -> Bool
    public var fileExists: @Sendable (String) -> Bool

    public init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        directoryExists: @escaping @Sendable (String) -> Bool = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        },
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.home = home
        self.directoryExists = directoryExists
        self.fileExists = fileExists
    }

    /// `resolved` is optional so the schema can be checked without spawning a shell.
    public func validate(_ config: TenderConfig, resolved: ResolvedEnvironment? = nil) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let names = config.services.keys.sorted()

        for name in names {
            let service = config.services[name]!
            if !Self.isValidName(name) {
                issues.append(.init(.error, name, "service names may use lowercase letters, digits and dashes, starting with a letter or digit."))
            }
            issues += checkShape(name, service)
            issues += checkPaths(name, service)
            issues += checkHealth(name, service)
            for dependency in service.dependsOn {
                if dependency == name {
                    issues.append(.init(.error, name, "depends on itself."))
                } else if config.services[dependency] == nil {
                    issues.append(.init(.error, name, "depends on “\(dependency)”, which isn’t a service in this file."))
                } else if config.services[dependency]?.health?.endpoint == nil {
                    issues.append(.init(.warning, name, "depends on “\(dependency)”, which has no health check, so Tender can’t wait for it to be ready."))
                }
            }
            if let command = service.command, let resolution = resolved?.commands[command] {
                if resolution.path == nil {
                    let hint = command.contains("/") ? "no executable file at that path." : "your login shell can’t find “\(command)” either."
                    issues.append(.init(.error, name, "command “\(command)” not found: \(hint)"))
                } else if let manager = resolution.versionManager {
                    let what = command.contains("/") ? "\(resolution.path!) belongs to \(manager)" : "“\(command)” comes from \(manager) (\(resolution.path!))"
                    issues.append(.init(.warning, name, "\(what). The path changes when you switch versions; Tender re-resolves it on every apply."))
                }
            }
        }

        if let cycle = DependencyOrder.cycle(in: config) {
            issues.append(.init(.error, nil, "dependencies form a loop: \(cycle.joined(separator: " → "))."))
        }
        issues += checkPortClashes(config)
        return issues
    }

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLowercase || first.isNumber else { return false }
        return name.allSatisfy { ($0.isLowercase && $0.isASCII) || ($0.isNumber && $0.isASCII) || $0 == "-" }
    }

    private func checkShape(_ name: String, _ service: ServiceConfig) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if service.isExternal {
            let managedOnly: [(String, Bool)] = [
                ("command", service.command != nil), ("args", !service.args.isEmpty), ("cwd", service.cwd != nil),
                ("env", !service.env.isEmpty), ("envFile", service.envFile != nil), ("build", service.build != nil),
            ]
            for (key, present) in managedOnly where present {
                issues.append(.init(.error, name, "“\(key)” doesn’t apply to an external service; Tender only watches “\(service.external!)”."))
            }
        } else if service.command == nil || service.command!.isEmpty {
            issues.append(.init(.error, name, "needs a “command” (or “external:” to watch a launchd job Tender doesn’t own)."))
        }
        if let serve = service.serve, !(1...65535).contains(serve) {
            issues.append(.init(.error, name, "“serve” must be a port between 1 and 65535."))
        }
        return issues
    }

    private func checkPaths(_ name: String, _ service: ServiceConfig) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        var cwdPath: String?
        if let cwd = service.cwd {
            let path = PathExpander.expand(cwd, home: home)
            cwdPath = path
            if !directoryExists(path) {
                issues.append(.init(.error, name, "working folder \(path) doesn’t exist."))
            }
        }
        if let envFile = service.envFile {
            let path = PathExpander.expand(envFile, home: home, base: cwdPath)
            if !envFile.hasPrefix("/"), !envFile.hasPrefix("~"), cwdPath == nil {
                issues.append(.init(.error, name, "“envFile” is relative, so the service needs a “cwd”."))
            } else if !fileExists(path) {
                issues.append(.init(.error, name, "env file \(path) doesn’t exist."))
            }
        }
        return issues
    }

    private func checkHealth(_ name: String, _ service: ServiceConfig) -> [ValidationIssue] {
        guard let health = service.health else { return [] }
        switch health.type {
        case .http:
            guard let url = health.url else {
                return [.init(.error, name, "an http health check needs a “url”.")]
            }
            guard let components = URLComponents(string: url), components.scheme == "http" || components.scheme == "https", components.host != nil else {
                return [.init(.error, name, "health url “\(url)” isn’t a valid http(s) URL.")]
            }
        case .tcp:
            guard let port = health.port else {
                return [.init(.error, name, "a tcp health check needs a “port”.")]
            }
            if !(1...65535).contains(port) {
                return [.init(.error, name, "health port must be between 1 and 65535.")]
            }
        }
        if health.timeout.seconds > health.interval.seconds {
            return [.init(.warning, name, "health timeout (\(health.timeout)) is longer than its interval (\(health.interval)).")]
        }
        return []
    }

    private func checkPortClashes(_ config: TenderConfig) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        var byPort: [Int: [String]] = [:]
        var byServe: [Int: [String]] = [:]
        for (name, service) in config.services {
            if let endpoint = service.health?.endpoint, ["127.0.0.1", "localhost", "0.0.0.0", "::1"].contains(endpoint.host) {
                byPort[endpoint.port, default: []].append(name)
            }
            if let serve = service.serve { byServe[serve, default: []].append(name) }
        }
        for (port, names) in byPort.sorted(by: { $0.key < $1.key }) where names.count > 1 {
            issues.append(.init(.warning, nil, "\(names.sorted().joined(separator: " and ")) both check port \(port). Two services can’t listen on the same port."))
        }
        for (port, names) in byServe.sorted(by: { $0.key < $1.key }) where names.count > 1 {
            issues.append(.init(.error, nil, "\(names.sorted().joined(separator: " and ")) both want to be served on tailnet port \(port)."))
        }
        return issues
    }
}
