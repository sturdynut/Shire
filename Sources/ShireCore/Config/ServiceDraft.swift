import Foundation

/// A service being added from a form. It becomes a YAML block that is inserted into config.yaml
/// without rewriting the rest of the file, so comments and layout survive.
public struct ServiceDraft: Equatable, Sendable {
    public enum HealthKind: String, CaseIterable, Sendable { case none, http, tcp }

    public var name = ""
    public var command = ""
    /// Space-separated; double quotes group words ("a b" is one argument).
    public var arguments = ""
    public var cwd = ""
    public var envFile = ""
    public var build = ""
    public var restart: RestartPolicy = .always
    public var dependsOn: [String] = []
    public var healthKind: HealthKind = .none
    public var healthURL = ""
    public var healthPort = ""
    public var adoptRunning = false

    public init() {}

    /// Splits `arguments` like a shell would for plain words and double-quoted groups.
    public var argumentList: [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var hasToken = false
        for character in arguments {
            if character == "\"" {
                quoted.toggle()
                hasToken = true
            } else if character.isWhitespace, !quoted {
                if hasToken { result.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }

    /// The service's YAML, indented as a child of `services:`.
    public func yaml(indent: String = "  ") -> String {
        let field = indent + indent
        var lines = ["\(indent)\(name.trimmingCharacters(in: .whitespaces)):"]
        lines.append("\(field)command: \(YAMLScalar.quote(command.trimmingCharacters(in: .whitespaces)))")
        let args = argumentList
        if !args.isEmpty { lines.append("\(field)args: [\(args.map(YAMLScalar.quote).joined(separator: ", "))]") }
        if !trimmed(cwd).isEmpty { lines.append("\(field)cwd: \(YAMLScalar.quote(trimmed(cwd)))") }
        if !trimmed(envFile).isEmpty { lines.append("\(field)envFile: \(YAMLScalar.quote(trimmed(envFile)))") }
        if !trimmed(build).isEmpty { lines.append("\(field)build: \(YAMLScalar.quote(trimmed(build)))") }
        if restart != .always { lines.append("\(field)restart: \(restart.rawValue)") }
        if !dependsOn.isEmpty { lines.append("\(field)dependsOn: [\(dependsOn.map(YAMLScalar.quote).joined(separator: ", "))]") }
        if adoptRunning { lines.append("\(field)adoptRunning: true") }
        switch healthKind {
        case .none: break
        case .http: lines.append("\(field)health: { type: http, url: \(YAMLScalar.quote(trimmed(healthURL))) }")
        case .tcp: lines.append("\(field)health: { type: tcp, port: \(trimmed(healthPort)) }")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Problems with the form itself, before the config-wide checks run.
    public func formIssues(existing: [String]) -> [String] {
        var issues: [String] = []
        let name = trimmed(self.name)
        if name.isEmpty {
            issues.append("Give the service a name.")
        } else if !Validator.isValidName(name) {
            issues.append("Names use lowercase letters, digits and dashes, like my-app.")
        } else if existing.contains(name) {
            issues.append("There’s already a service called \(name).")
        }
        if trimmed(command).isEmpty { issues.append("Choose a command or an app.") }
        switch healthKind {
        case .none: break
        case .http:
            if URLComponents(string: trimmed(healthURL))?.host == nil { issues.append("The health check needs a URL like http://localhost:3000/health.") }
        case .tcp:
            if !(1...65535).contains(Int(trimmed(healthPort)) ?? 0) { issues.append("The health check needs a port between 1 and 65535.") }
        }
        if adoptRunning, healthKind == .none { issues.append("“Watch a copy you opened” needs a health check, so Shire can tell it’s running.") }
        return issues
    }

    /// For a picked `.app`, the executable inside it.
    public static func executable(inApp appURL: URL) -> String? {
        guard let bundle = Bundle(url: appURL), let executable = bundle.executableURL else { return nil }
        return executable.path
    }
}

public enum YAMLScalar {
    /// Quotes a scalar only when plain YAML would misread it.
    public static func quote(_ text: String) -> String {
        if text.isEmpty { return "\"\"" }
        let special: Set<Character> = [":", "#", "{", "}", "[", "]", ",", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"]
        let reserved = ["true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"]
        let needsQuotes = text.contains(where: { special.contains($0) })
            || text.first.map { " -?".contains($0) } == true
            || text.last == " "
            || reserved.contains(text.lowercased())
            || Double(text) != nil
        guard needsQuotes else { return text }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Inserts a service block into config.yaml text, touching nothing else.
public enum ConfigEditing {
    /// nil when the file's `services` is written inline (`services: { a: … }`), where no insertion is safe.
    public static func adding(_ block: String, to text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        guard let servicesIndex = lines.firstIndex(where: { isTopLevelKey($0, "services") }) else {
            // No services section yet: add one at the end.
            var result = lines
            if let last = result.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { result.append("") }
            result.append("services:")
            return (result + blockLines(block)).joined(separator: "\n") + "\n"
        }

        let header = lines[servicesIndex]
        if let value = valueAfterColon(header), value.hasPrefix("{") {
            // `services: {}` (or an inline map): only the empty form is safe to expand.
            guard value.replacingOccurrences(of: " ", with: "").hasPrefix("{}") else { return nil }
            lines[servicesIndex] = "services:" + commentSuffix(header)
            lines.insert(contentsOf: blockLines(block), at: servicesIndex + 1)
            return lines.joined(separator: "\n") + "\n"
        }

        // The section runs until the next top-level key; insert after its last non-blank line.
        var end = servicesIndex + 1
        while end < lines.count, !isTopLevel(lines[end]) { end += 1 }
        var insertAt = end
        while insertAt > servicesIndex + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        let indent = childIndent(lines, from: servicesIndex + 1, to: end) ?? "  "
        var block = reindent(block, to: indent)
        // Keep services separated by a blank line when the file already does that.
        let separated = lines[(servicesIndex + 1)..<end].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        if separated, insertAt > servicesIndex + 1 { block = "\n" + block }
        lines.insert(contentsOf: blockLines(block), at: insertAt)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Helpers

    static func isTopLevel(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return !first.isWhitespace && first != "#"
    }

    static func isTopLevelKey(_ line: String, _ key: String) -> Bool {
        isTopLevel(line) && (line.hasPrefix("\(key):"))
    }

    static func valueAfterColon(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let rest = line[line.index(after: colon)...]
        let beforeComment = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let value = beforeComment.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// The whitespace and comment after a line's value, exactly as written.
    static func commentSuffix(_ line: String) -> String {
        guard let hash = line.range(of: " #")?.upperBound else { return "" }
        var start = line.index(before: hash)
        while start > line.startIndex, line[line.index(before: start)] == " " { start = line.index(before: start) }
        return String(line[start...])
    }

    static func childIndent(_ lines: [String], from start: Int, to end: Int) -> String? {
        for line in lines[start..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            return String(line.prefix { $0 == " " })
        }
        return nil
    }

    static func reindent(_ block: String, to indent: String) -> String {
        guard indent != "  " else { return block }
        return block.components(separatedBy: "\n").map { line in
            let spaces = line.prefix { $0 == " " }.count
            let level = spaces / 2
            return String(repeating: indent, count: level) + line.dropFirst(spaces)
        }.joined(separator: "\n")
    }

    static func blockLines(_ block: String) -> [String] {
        var lines = block.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
