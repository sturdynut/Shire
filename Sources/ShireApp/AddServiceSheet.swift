import AppKit
import ShireCore
import SwiftUI

/// "Add service…": a form that writes one new service into config.yaml and leaves the rest of the file as it was.
struct AddServiceSheet: View {
    @Bindable var model: ShireModel
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable { case command = "Command", app = "App" }

    @State private var kind: Kind = .command
    @State private var draft = ServiceDraft()
    @State private var appPath = ""
    @State private var resolved: String?
    @State private var resolving = false
    @State private var saveError: String?
    @State private var showAdvanced = false

    private var existing: [String] { model.snapshot?.config?.services.keys.sorted() ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Runs", selection: $kind) {
                        ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Name", text: $draft.name, prompt: Text("bagend-api"))
                    if kind == .app {
                        LabeledContent("App") {
                            HStack {
                                Text(appPath.isEmpty ? "None chosen" : (appPath as NSString).lastPathComponent)
                                    .foregroundStyle(appPath.isEmpty ? .secondary : .primary)
                                Spacer()
                                Button("Choose…") { chooseApp() }
                            }
                        }
                        Toggle("If it’s already open, watch that copy instead of launching another", isOn: $draft.adoptRunning)
                    } else {
                        TextField("Command", text: $draft.command, prompt: Text("node, pnpm, or a full path"))
                        commandHint
                    }
                    TextField("Arguments", text: $draft.arguments, prompt: Text(kind == .app ? "--remote-debugging-port=9222" : "dist/index.js"))
                    LabeledContent("Working folder") {
                        HStack {
                            TextField("", text: $draft.cwd, prompt: Text("~/Code/bagend/server")).labelsHidden()
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                }

                Section("Health check") {
                    Picker("Check", selection: $draft.healthKind) {
                        Text("None").tag(ServiceDraft.HealthKind.none)
                        Text("HTTP").tag(ServiceDraft.HealthKind.http)
                        Text("TCP port").tag(ServiceDraft.HealthKind.tcp)
                    }
                    .pickerStyle(.segmented)
                    if draft.healthKind == .http {
                        TextField("URL", text: $draft.healthURL, prompt: Text("http://localhost:3000/health"))
                    } else if draft.healthKind == .tcp {
                        TextField("Port", text: $draft.healthPort, prompt: Text("5432"))
                    }
                }

                Section("Starting") {
                    Picker("Restart", selection: $draft.restart) {
                        Text("Always").tag(RestartPolicy.always)
                        Text("If it fails").tag(RestartPolicy.onFailure)
                        Text("Never").tag(RestartPolicy.never)
                    }
                    if !existing.isEmpty {
                        LabeledContent("Start after") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(existing, id: \.self) { name in
                                    Toggle(name, isOn: dependsBinding(name)).toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                    DisclosureGroup("More", isExpanded: $showAdvanced) {
                        TextField("Build step", text: $draft.build, prompt: Text("pnpm build"))
                        TextField("Env file", text: $draft.envFile, prompt: Text(".env (relative to the working folder)"))
                    }
                }

                Section("Will add to config.yaml") {
                    Text(draft.yaml())
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(problems, id: \.self) { problem in
                        CheckRow(ok: false, text: problem)
                    }
                    ForEach(warnings, id: \.self) { warning in
                        CheckRow(ok: nil, text: warning)
                    }
                    if let saveError { CheckRow(ok: false, text: saveError) }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Edit or remove services later in config.yaml.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { save(apply: false) }.disabled(!problems.isEmpty)
                Button("Add & Apply") { save(apply: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 560, height: 680)
        .task(id: draft.command) { await resolveCommand() }
    }

    // MARK: Checks

    @ViewBuilder
    private var commandHint: some View {
        if resolving {
            HStack { ProgressView().controlSize(.small); Text("Finding it…").font(.caption) }
        } else if let resolved {
            Text("→ \(resolved)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        } else if !draft.command.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Not found in your login shell").font(.caption).foregroundStyle(.red)
        }
    }

    /// Errors that block adding: the form's own, plus config-wide checks about this service.
    private var problems: [String] {
        let form = draft.formIssues(existing: existing)
        guard form.isEmpty else { return form }
        guard let candidate else { return ["Your config.yaml writes `services` on one line; add this one in the config.yaml editor."] }
        do {
            let config = try ConfigLoader.parse(candidate)
            return Validator().validate(config).filter { $0.severity == .error && $0.service == name }.map(\.message)
        } catch {
            return [String(describing: error)]
        }
    }

    private var warnings: [String] {
        guard let candidate, let config = try? ConfigLoader.parse(candidate) else { return [] }
        return Validator().validate(config).filter { $0.severity == .warning && $0.service == name }.map(\.message)
    }

    private var name: String { draft.name.trimmingCharacters(in: .whitespaces) }

    private var currentText: String { (try? String(contentsOf: model.paths.configFile, encoding: .utf8)) ?? "" }

    private var candidate: String? { ConfigEditing.adding(draft.yaml(), to: currentText) }

    private func resolveCommand() async {
        let command = draft.command.trimmingCharacters(in: .whitespaces)
        resolved = nil
        guard !command.isEmpty, kind == .command else { return }
        try? await Task.sleep(for: .milliseconds(500))
        if Task.isCancelled { return }
        resolving = true
        let path = await Task.detached { (try? CommandResolver().resolve([command]))?.commands[command]?.path }.value
        if Task.isCancelled { return }
        resolving = false
        resolved = path
    }

    private func dependsBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { draft.dependsOn.contains(name) },
            set: { on in
                if on { draft.dependsOn.append(name) } else { draft.dependsOn.removeAll { $0 == name } }
            }
        )
    }

    // MARK: Pickers

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let executable = ServiceDraft.executable(inApp: url) else { return }
        appPath = url.path
        draft.command = executable
        if draft.name.isEmpty {
            draft.name = url.deletingPathExtension().lastPathComponent.lowercased()
                .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
                .split(separator: "-").joined(separator: "-")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Code")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.cwd = (url.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Save

    private func save(apply: Bool) {
        // Re-read the file right before writing, so an edit made elsewhere since the sheet opened isn't lost.
        guard let updated = ConfigEditing.adding(draft.yaml(), to: currentText) else {
            saveError = "Couldn’t find a safe place for it in config.yaml."
            return
        }
        do {
            try FileManager.default.createDirectory(at: model.paths.configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: model.paths.configFile, atomically: true, encoding: .utf8)
        } catch {
            saveError = "Couldn’t save config.yaml: \(error.localizedDescription)"
            return
        }
        model.configRevision += 1
        model.selection = .service(name)
        if apply { model.apply() } else { model.refresh() }
        dismiss()
    }
}
