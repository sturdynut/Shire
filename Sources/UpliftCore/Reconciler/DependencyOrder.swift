import Foundation

public enum DependencyOrder {
    /// Service names with dependencies before dependents; ties broken alphabetically so output is stable.
    /// Services in a cycle (which validation reports) are appended at the end.
    public static func sorted(_ config: UpliftConfig) -> [String] {
        var remaining = Set(config.services.keys)
        var result: [String] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { name in
                config.services[name]!.dependsOn.allSatisfy { !remaining.contains($0) || $0 == name }
            }.sorted()
            if ready.isEmpty {
                result += remaining.sorted()
                break
            }
            result += ready
            remaining.subtract(ready)
        }
        return result
    }

    /// One dependency loop, as a path like `a → b → a`, or nil.
    public static func cycle(in config: UpliftConfig) -> [String]? {
        enum Mark { case visiting, done }
        var marks: [String: Mark] = [:]
        var stack: [String] = []

        func visit(_ name: String) -> [String]? {
            if marks[name] == .done { return nil }
            if marks[name] == .visiting {
                let start = stack.firstIndex(of: name)!
                return Array(stack[start...]) + [name]
            }
            marks[name] = .visiting
            stack.append(name)
            for dependency in config.services[name]?.dependsOn ?? [] where dependency != name && config.services[dependency] != nil {
                if let found = visit(dependency) { return found }
            }
            stack.removeLast()
            marks[name] = .done
            return nil
        }

        for name in config.services.keys.sorted() {
            if let found = visit(name) { return found }
        }
        return nil
    }
}
