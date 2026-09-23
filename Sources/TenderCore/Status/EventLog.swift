import Foundation

/// One start or exit of a service, written by `tender run` so `status` can tell a crash loop from a single crash.
public struct ServiceEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case start, exit }

    public var time: Date
    public var kind: Kind
    public var code: Int32?
    public var command: String?
    public var message: String?

    public init(time: Date, kind: Kind, code: Int32? = nil, command: String? = nil, message: String? = nil) {
        self.time = time
        self.kind = kind
        self.code = code
        self.command = command
        self.message = message
    }
}

public struct EventLog: Sendable {
    public var url: URL
    public var keepLines: Int

    public init(url: URL, keepLines: Int = 200) {
        self.url = url
        self.keepLines = keepLines
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    public func append(_ event: ServiceEvent) {
        guard var data = try? Self.encoder.encode(event) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        if let size = try? handle.seekToEnd(), size > UInt64(keepLines * 400) {
            try? handle.close()
            compact()
            if let fresh = try? FileHandle(forWritingTo: url) {
                _ = try? fresh.seekToEnd()
                try? fresh.write(contentsOf: data)
                try? fresh.close()
            }
            return
        }
        try? handle.write(contentsOf: data)
    }

    public func read() -> [ServiceEvent] {
        LogReader.tail(url, lines: keepLines).compactMap { line in
            try? Self.decoder.decode(ServiceEvent.self, from: Data(line.utf8))
        }
    }

    private func compact() {
        let recent = LogReader.tail(url, lines: keepLines / 2)
        try? (recent.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
