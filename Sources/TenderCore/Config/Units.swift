import Foundation

/// A length of time written the way people write it in YAML: `500ms`, `30s`, `2m`, `1h`, or a bare number of seconds.
public struct DurationValue: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }

    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, Double)] = [("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600)]
        for (suffix, factor) in units where trimmed.hasSuffix(suffix) {
            let number = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number), value >= 0 else { return nil }
            self.seconds = value * factor
            return
        }
        guard let value = Double(trimmed), value >= 0 else { return nil }
        self.seconds = value
    }

    public var description: String {
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(seconds / 3600))h" }
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(seconds / 60))m" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds.truncatingRemainder(dividingBy: 1) == 0 { return "\(Int(seconds))s" }
        return "\(seconds)s"
    }
}

/// A size in bytes written as `10MB`, `512KB`, `1GB` or a bare number of bytes.
public struct ByteSize: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var bytes: Int

    public init(bytes: Int) {
        self.bytes = bytes
    }

    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        let units: [(String, Int)] = [("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10), ("B", 1)]
        for (suffix, factor) in units where trimmed.hasSuffix(suffix) {
            let number = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number), value > 0 else { return nil }
            self.bytes = Int(value * Double(factor))
            return
        }
        guard let value = Int(trimmed), value > 0 else { return nil }
        self.bytes = value
    }

    public var description: String {
        for (suffix, factor) in [("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)] where bytes >= factor && bytes % factor == 0 {
            return "\(bytes / factor)\(suffix)"
        }
        return "\(bytes)B"
    }
}

/// "N restarts within a window", written as `3 in 5m`.
public struct CrashLoopRule: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var count: Int
    public var window: DurationValue

    public init(count: Int, window: DurationValue) {
        self.count = count
        self.window = window
    }

    public init?(parsing text: String) {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[1].lowercased() == "in",
              let count = Int(parts[0]), count > 0,
              let window = DurationValue(parsing: String(parts[2])), window.seconds > 0
        else { return nil }
        self.count = count
        self.window = window
    }

    public var description: String { "\(count) in \(window)" }

    public static let `default` = CrashLoopRule(count: 3, window: DurationValue(seconds: 300))
}

extension DurationValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self.init(seconds: number)
            return
        }
        let text = try container.decode(String.self)
        guard let value = DurationValue(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "“\(text)” isn’t a duration. Use values like 500ms, 30s, 2m or 1h.")
        }
        self = value
    }
}

extension ByteSize: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self.init(bytes: number)
            return
        }
        let text = try container.decode(String.self)
        guard let value = ByteSize(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "“\(text)” isn’t a size. Use values like 512KB, 10MB or 1GB.")
        }
        self = value
    }
}

extension CrashLoopRule: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = CrashLoopRule(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "“\(text)” isn’t a crash-loop rule. Write it like “3 in 5m”.")
        }
        self = value
    }
}
