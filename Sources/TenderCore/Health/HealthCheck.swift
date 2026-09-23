import Foundation

public enum HealthResult: Equatable, Sendable {
    case healthy(detail: String)
    case unhealthy(detail: String)

    public var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }

    public var detail: String {
        switch self {
        case .healthy(let detail), .unhealthy(let detail): return detail
        }
    }
}

/// One-shot health checks. Continuous checking belongs to tender-agent (Phase 3); `status` and dependency waits use these.
public enum HealthProbe {
    public static func check(_ config: HealthCheckConfig) async -> HealthResult {
        switch config.type {
        case .tcp:
            guard let endpoint = config.endpoint else { return .unhealthy(detail: "no port configured") }
            let started = Date()
            if tcpConnect(endpoint, timeout: config.timeout.seconds) {
                return .healthy(detail: "port \(endpoint.port) open · \(milliseconds(since: started)) ms")
            }
            return .unhealthy(detail: "port \(endpoint.port) closed")
        case .http:
            guard let text = config.url, let url = URL(string: text) else { return .unhealthy(detail: "no url configured") }
            return await http(url, timeout: config.timeout.seconds)
        }
    }

    public static func http(_ url: URL, timeout: TimeInterval) async -> HealthResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let started = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ms = milliseconds(since: started)
            // Anything below 500 means the app answered; a 404 on `/` is still a running web server.
            if (200..<500).contains(status) {
                return .healthy(detail: "HTTP \(status) · \(ms) ms")
            }
            return .unhealthy(detail: "HTTP \(status)")
        } catch let error as URLError {
            switch error.code {
            case .timedOut: return .unhealthy(detail: "no answer within \(DurationValue(seconds: timeout))")
            case .cannotConnectToHost: return .unhealthy(detail: "connection refused")
            default: return .unhealthy(detail: error.localizedDescription)
            }
        } catch {
            return .unhealthy(detail: error.localizedDescription)
        }
    }

    /// A plain non-blocking connect with a deadline. Tries every address the host resolves to.
    public static func tcpConnect(_ endpoint: HostPort, timeout: TimeInterval) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(endpoint.host, String(endpoint.port), &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            defer { cursor = info.pointee.ai_next }
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let rc = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
            if rc == 0 { return true }
            guard errno == EINPROGRESS else { continue }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(max(1, timeout * 1000)))
            guard ready > 0 else { continue }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            if error == 0 { return true }
        }
        return false
    }

    private static func milliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }
}
