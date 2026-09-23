import AppKit
import SwiftUI
import ShireCore

/// config.yaml, edited in place with live checks. Shire watches the file, so edits in another editor show up here too.
struct ConfigEditor: View {
    @Bindable var model: ShireModel
    @State private var text = ""
    @State private var saved = ""
    @State private var loadedAt: Date?
    @State private var parseError: String?
    @State private var issues: [ValidationIssue] = []
    @State private var resolved: [String: String] = [:]
    @State private var checking = false
    @State private var plan = ""

    private var dirty: Bool { text != saved }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .frame(minWidth: 380)
                checks
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
            }
        }
        .task { load() }
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(400))
            checkSchema()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("config.yaml").font(.headline)
                Text(model.paths.configFile.path).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if dirty { Text("Unsaved").font(.caption).foregroundStyle(.orange) }
            Button("Open in editor") { model.openConfig() }
            Button("Revert") { load() }.disabled(!dirty)
            Button("Save") { save() }.keyboardShortcut("s").disabled(!dirty || parseError != nil)
            Button(model.busy.contains("apply") ? "Applying…" : "Save & Apply") {
                if dirty { save() }
                model.apply()
            }
            .buttonStyle(.borderedProminent)
            .disabled(parseError != nil || model.busy.contains("apply"))
        }
        .padding(12)
    }

    private var checks: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Checks").font(.headline)
                if let parseError {
                    CheckRow(ok: false, text: parseError)
                } else {
                    CheckRow(ok: true, text: "YAML is valid")
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        CheckRow(ok: issue.severity == .warning ? nil : false, text: issue.description)
                    }
                    if checking {
                        HStack { ProgressView().controlSize(.small); Text("Finding commands…").font(.caption) }
                    } else if !resolved.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Commands").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(resolved.keys.sorted(), id: \.self) { key in
                                Text("\(key) → \(resolved[key]!)").font(.caption2.monospaced()).lineLimit(2).textSelection(.enabled)
                            }
                        }
                    }
                }
                if !plan.isEmpty {
                    Divider()
                    Text("Apply will").font(.headline)
                    Text(plan).font(.caption.monospaced()).textSelection(.enabled)
                }
                if let outcome = model.lastOutcome, outcome.title == "Apply changes" {
                    Divider()
                    OutcomeLine(outcome: outcome)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() {
        let content = (try? String(contentsOf: model.paths.configFile, encoding: .utf8)) ?? ""
        text = content
        saved = content
        loadedAt = Date()
        checkSchema()
        checkCommandsAndPlan()
    }

    private func save() {
        do {
            try text.write(to: model.paths.configFile, atomically: true, encoding: .utf8)
            saved = text
            checkCommandsAndPlan()
        } catch {
            parseError = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    /// Instant: parse and validate without spawning anything.
    private func checkSchema() {
        do {
            let config = try ConfigLoader.parse(text)
            parseError = nil
            issues = Validator().validate(config)
        } catch {
            parseError = String(describing: error)
            issues = []
        }
    }

    /// Slower (a login shell and a dry run), so only on load and save.
    private func checkCommandsAndPlan() {
        guard let config = try? ConfigLoader.parse(saved) else { return }
        checking = true
        Task.detached {
            let commands = config.services.values.compactMap { $0.isExternal ? nil : $0.command }
            let environment = try? CommandResolver().resolve(commands)
            let issues = Validator().validate(config, resolved: environment)
            let dryRun = ShireCLI.run(["apply", "--dry-run"], title: "Plan")
            let planLines = dryRun.output.split(separator: "\n").filter { $0.hasPrefix("→") || $0.hasPrefix("·") || $0.hasPrefix("✓") || $0.hasPrefix("Nothing") }
            await MainActor.run {
                self.checking = false
                self.issues = issues
                self.resolved = (environment?.commands ?? [:]).reduce(into: [:]) { $0[$1.key] = $1.value.path ?? "not found" }
                self.plan = planLines.joined(separator: "\n")
            }
        }
    }
}

struct CheckRow: View {
    /// true = ok, false = error, nil = warning
    var ok: Bool?
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok == true ? .green : ok == false ? .red : .orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}
