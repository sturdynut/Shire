import Foundation
import Testing
@testable import ShireCore

/// Open file descriptors in this process.
func openDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
}

@Suite("Running commands", .serialized)
struct ShellTests {
    @Test func capturesOutputAndStatus() throws {
        let result = try SystemCommandRunner().run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
        #expect(result.status == 3)
    }

    /// tender-agent runs commands forever; each run must give back every descriptor it opened.
    @Test func doesNotLeakFileDescriptors() throws {
        let runner = SystemCommandRunner()
        _ = try runner.run("/bin/echo", ["warm up"])
        // Other test suites open files in parallel, so allow some noise: the bug this guards against leaked
        // 2 descriptors per run (600 here), far above it.
        let before = openDescriptorCount()
        for _ in 0..<300 { _ = try runner.run("/bin/echo", ["hi"]) }
        Thread.sleep(forTimeInterval: 0.5)
        let after = openDescriptorCount()
        #expect(after - before < 60, "leaked \(after - before) descriptors over 300 runs")
    }
}
