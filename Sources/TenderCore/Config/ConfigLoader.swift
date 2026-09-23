import Foundation
import Yams

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case fileNotFound(String)
    case invalidYAML(String)
    case unknownKey(path: String, key: String, suggestion: String?)
    case invalidValue(path: String, message: String)

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "No config file at \(path). Create it, or pass --config."
        case .invalidYAML(let message):
            return "config.yaml isn’t valid YAML: \(message)"
        case .unknownKey(let path, let key, let suggestion):
            let place = path.isEmpty ? "at the top level" : "in \(path)"
            if let suggestion { return "Unknown key “\(key)” \(place). Did you mean “\(suggestion)”?" }
            return "Unknown key “\(key)” \(place)."
        case .invalidValue(let path, let message):
            return path.isEmpty ? message : "\(path): \(message)"
        }
    }
}

public enum ConfigLoader {
    public static func load(from url: URL) throws -> TenderConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.fileNotFound(url.path)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> TenderConfig {
        let node: Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch {
            throw ConfigError.invalidYAML(String(describing: error))
        }
        guard let node else { return TenderConfig() }
        try checkKeys(node)

        let raw: RawConfig
        do {
            raw = try YAMLDecoder().decode(RawConfig.self, from: text)
        } catch let error as DecodingError {
            throw describe(error)
        } catch {
            throw ConfigError.invalidYAML(String(describing: error))
        }
        return TenderConfig(
            serverMode: raw.serverMode ?? ServerMode(),
            presets: raw.presets ?? Presets(),
            remote: raw.remote ?? RemoteSettings(),
            alerts: raw.alerts ?? AlertSettings(),
            logs: raw.logs ?? LogSettings(),
            services: raw.services ?? [:]
        )
    }

    // MARK: - Strict keys

    private struct RawConfig: Decodable {
        var serverMode: ServerMode?
        var presets: Presets?
        var remote: RemoteSettings?
        var alerts: AlertSettings?
        var logs: LogSettings?
        var services: [String: ServiceConfig]?
    }

    private static let rootKeys = ["serverMode", "presets", "remote", "alerts", "logs", "services"]
    private static let sectionKeys: [String: [String]] = [
        "serverMode": ServerMode.CodingKeys.allCases.map(\.rawValue),
        "presets": Presets.CodingKeys.allCases.map(\.rawValue),
        "remote": RemoteSettings.CodingKeys.allCases.map(\.rawValue),
        "alerts": AlertSettings.CodingKeys.allCases.map(\.rawValue),
        "logs": LogSettings.CodingKeys.allCases.map(\.rawValue),
    ]
    private static let serviceKeys = ServiceConfig.CodingKeys.allCases.map(\.rawValue)
    private static let healthKeys = HealthCheckConfig.CodingKeys.allCases.map(\.rawValue)
    private static let tailscaleKeys = TailscalePreset.CodingKeys.allCases.map(\.rawValue)

    /// Rejects keys the schema doesn't know, so a typo like `dependOn` fails loudly instead of being ignored.
    private static func checkKeys(_ root: Node) throws {
        guard let mapping = root.mapping else {
            throw ConfigError.invalidValue(path: "", message: "config.yaml must be a mapping of sections (services:, alerts:, …).")
        }
        try check(mapping, allowed: rootKeys, path: "")
        for (keyNode, value) in mapping {
            guard let key = keyNode.string else { continue }
            if let allowed = sectionKeys[key], let section = value.mapping {
                try check(section, allowed: allowed, path: key)
                if key == "presets", let tailscale = section["tailscale"]?.mapping {
                    try check(tailscale, allowed: tailscaleKeys, path: "presets.tailscale")
                }
            }
            if key == "services", let services = value.mapping {
                for (nameNode, serviceNode) in services {
                    guard let name = nameNode.string, let service = serviceNode.mapping else { continue }
                    try check(service, allowed: serviceKeys, path: "services.\(name)")
                    if let health = service["health"]?.mapping {
                        try check(health, allowed: healthKeys, path: "services.\(name).health")
                    }
                }
            }
        }
    }

    private static func check(_ mapping: Node.Mapping, allowed: [String], path: String) throws {
        for (keyNode, _) in mapping {
            guard let key = keyNode.string else { continue }
            if !allowed.contains(key) {
                throw ConfigError.unknownKey(path: path, key: key, suggestion: closest(to: key, in: allowed))
            }
        }
    }

    private static func closest(to key: String, in candidates: [String]) -> String? {
        let scored = candidates.map { ($0, editDistance($0.lowercased(), key.lowercased())) }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= max(2, key.count / 3) else { return nil }
        return best.0
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: - Decoding errors

    private static func describe(_ error: DecodingError) -> ConfigError {
        func path(_ codingPath: [CodingKey]) -> String {
            codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
                .joined(separator: ".")
                .replacingOccurrences(of: ".[", with: "[")
        }
        switch error {
        case .typeMismatch(let type, let context):
            return .invalidValue(path: path(context.codingPath), message: "expected \(friendly(type)).")
        case .valueNotFound(let type, let context):
            return .invalidValue(path: path(context.codingPath), message: "missing \(friendly(type)).")
        case .keyNotFound(let key, let context):
            let where_ = path(context.codingPath)
            return .invalidValue(path: where_, message: "missing required key “\(key.stringValue)”.")
        case .dataCorrupted(let context):
            return .invalidValue(path: path(context.codingPath), message: context.debugDescription)
        @unknown default:
            return .invalidYAML(String(describing: error))
        }
    }

    private static func friendly(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: return "text"
        case is Bool.Type: return "true or false"
        case is Int.Type, is Double.Type: return "a number"
        case is [String].Type: return "a list"
        case is [String: String].Type: return "a mapping of names to values"
        default: return "a different kind of value"
        }
    }
}
