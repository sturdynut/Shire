import Foundation

/// An append-only log file that rotates to `.1`, `.2`, … once it passes `maxBytes`.
/// A service that crash-loops writes fast on a Mac that never restarts, so rotation isn't optional.
public final class RotatingLog: @unchecked Sendable {
    public let url: URL
    public let maxBytes: Int
    public let keep: Int

    private let lock = NSLock()
    private var handle: FileHandle?
    private var size: Int = 0

    public init(url: URL, maxBytes: Int, keep: Int) throws {
        self.url = url
        self.maxBytes = max(1024, maxBytes)
        self.keep = max(0, keep)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try open()
    }

    deinit {
        try? handle?.close()
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            if size > 0, size + data.count > maxBytes {
                rotate()
            }
            do {
                try handle?.write(contentsOf: data)
                size += data.count
            } catch {
                // Nothing sensible to do if the disk is full; dropping log lines beats crashing the service.
            }
        }
    }

    public func write(line: String) {
        write(Data((line.hasSuffix("\n") ? line : line + "\n").utf8))
    }

    private func open() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        size = Int(try handle.seekToEnd())
        self.handle = handle
    }

    private func rotate() {
        let fm = FileManager.default
        try? handle?.close()
        handle = nil
        if keep == 0 {
            try? fm.removeItem(at: url)
        } else {
            try? fm.removeItem(at: rotated(keep))
            if keep > 1 {
                for index in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: rotated(index).path) {
                    try? fm.moveItem(at: rotated(index), to: rotated(index + 1))
                }
            }
            try? fm.moveItem(at: url, to: rotated(1))
        }
        try? open()
    }

    private func rotated(_ index: Int) -> URL {
        url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).\(index)")
    }
}

public enum LogReader {
    /// The last `count` lines of a file, reading only its end.
    public static func tail(_ url: URL, lines count: Int, maxBytes: Int = 256 * 1024) -> [String] {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return Array(lines.suffix(count))
    }
}
