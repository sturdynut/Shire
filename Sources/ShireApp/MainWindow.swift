import AppKit
import SwiftUI
import ShireCore

struct MainWindow: View {
    @Bindable var model: ShireModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Server") {
                    Label {
                        HStack {
                            Text("Readiness")
                            Spacer()
                            if !model.readinessWarnings.isEmpty {
                                Text("\(model.readinessWarnings.count)").font(.caption.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.orange.opacity(0.25)))
                            }
                        }
                    } icon: { Image(systemName: "checkmark.shield") }
                    .tag(SidebarItem.readiness)
                    Label("Alerts", systemImage: "bell").tag(SidebarItem.alerts)
                }
                Section("Services") {
                    ForEach(model.snapshot?.services ?? []) { service in
                        HStack(spacing: 8) {
                            StatusDot(color: service.tone.color)
                            Text(service.name)
                        }
                        .tag(SidebarItem.service(service.name))
                    }
                }
                Section("Configuration") {
                    Label("config.yaml", systemImage: "doc.text").tag(SidebarItem.config)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    StatusDot(color: menuColor, size: 8)
                    Text(model.headline).font(.caption.weight(.semibold))
                    Spacer()
                }
                .padding(10)
            }
        } detail: {
            Group {
                switch model.selection {
                case .service(let name)?: ServiceDetail(model: model, name: name)
                case .config?: ConfigEditor(model: model)
                case .alerts?: AlertsView(model: model)
                default: ReadinessView(model: model)
                }
            }
            .frame(minWidth: 640, minHeight: 520)
        }
    }

    private var menuColor: Color {
        switch model.overall {
        case .healthy: return .green
        case .attention: return .orange
        case .notRunning: return .gray
        }
    }
}

// MARK: - Service

struct ServiceDetail: View {
    @Bindable var model: ShireModel
    var name: String
    @State private var stream = "Both"
    @State private var lines: [String] = []
    @State private var follow = true

    var body: some View {
        if let service = model.service(name) {
            VStack(alignment: .leading, spacing: 16) {
                header(service)
                stats(service)
                if let cause = service.cause {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Likely cause").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            Text(cause)
                        }
                    } icon: { Image(systemName: "lightbulb").foregroundStyle(.teal) }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.08)))
                }
                if service.config.isExternal {
                    Text("Shire only watches \(service.config.external ?? name); its logs live wherever that job writes them.")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    logs(service)
                }
            }
            .padding(20)
            .task(id: "\(name)-\(stream)") { await tailLogs() }
        } else {
            ContentUnavailableView("No service named \(name)", systemImage: "questionmark.circle")
        }
    }

    private func header(_ service: ShireSnapshot.Service) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(name).font(.title2.weight(.semibold))
                    Text(service.stateText).font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(service.tone.color.opacity(0.18)))
                        .foregroundStyle(service.tone.color)
                }
                Text(commandLine(service)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if model.busy.contains(name) { ProgressView().controlSize(.small) }
            if !service.config.isExternal {
                if service.process == .stopped || service.process == .notInstalled {
                    Button("Start") { model.start(name) }
                } else {
                    Button("Stop", role: .destructive) { model.stop(name) }
                }
                Button("Restart") { model.restart(name) }.keyboardShortcut("r")
            }
            if let url = service.url {
                Button { model.open(url) } label: { Label("Open", systemImage: "arrow.up.right.square") }
            }
        }
        .disabled(model.busy.contains(name))
    }

    private func commandLine(_ service: ShireSnapshot.Service) -> String {
        if let external = service.config.external { return "external · \(external)" }
        let command = ([service.config.command ?? ""] + service.config.args).joined(separator: " ")
        return [command, service.config.cwd.map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
    }

    private func stats(_ service: ShireSnapshot.Service) -> some View {
        Grid(horizontalSpacing: 12) {
            GridRow {
                StatTile(label: "Process", value: service.process.menuLabel, sub: processDetail(service))
                StatTile(label: "Health", value: service.health.map { $0.isHealthy ? "Healthy" : "Unhealthy" } ?? "No check",
                         sub: [service.health?.detail, service.healthNote].compactMap { $0 }.joined(separator: " · "))
                StatTile(label: "Health check", value: healthCheckText(service), sub: service.config.health.map { "every \($0.interval)" } ?? "")
                StatTile(label: "Restart", value: service.config.isExternal ? "Not managed" : service.config.restart.rawValue.capitalized,
                         sub: service.config.dependsOn.isEmpty ? "no dependencies" : "after \(service.config.dependsOn.joined(separator: ", "))")
            }
        }
    }

    private func processDetail(_ service: ShireSnapshot.Service) -> String {
        switch service.process {
        case .running(let pid, let since):
            return "pid \(pid)" + (since.map { " · up \(Readiness.describe(Date().timeIntervalSince($0)))" } ?? "")
        case .crashLooping(let code, let exits, let window): return "exit \(code) · \(exits) in \(window)"
        case .external(_, let pid): return pid.map { "pid \($0)" } ?? ""
        default: return ""
        }
    }

    private func healthCheckText(_ service: ShireSnapshot.Service) -> String {
        guard let check = service.config.health else { return "None" }
        switch check.type {
        case .http: return check.url.map { URLComponents(string: $0)?.port.map { ":\($0)" } ?? $0 } ?? "HTTP"
        case .tcp: return "TCP :\(check.port ?? 0)"
        }
    }

    private func logs(_ service: ShireSnapshot.Service) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $stream) {
                    Text("Both").tag("Both")
                    Text("stdout").tag("stdout")
                    Text("stderr").tag("stderr")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
                Text("Last 200 lines · rotates at \(model.snapshot?.config?.logs.maxSize.description ?? "10MB")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.revealLogs(name) } label: { Label("Reveal in Finder", systemImage: "folder") }
            }
            .padding(10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: lines.count) { _, count in
                    if follow, count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            .background(Color(white: 0.1))
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.14)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .environment(\.colorScheme, .dark)
    }

    private func color(for line: String) -> Color {
        if line.contains(" shire: ") {
            return line.contains("exited 0") || !(line.contains("exited") || line.contains("no such") || line.contains("gave up") || line.contains("right away")) ? .secondary : .red.opacity(0.9)
        }
        return .primary
    }

    private func tailLogs() async {
        while !Task.isCancelled {
            let paths = model.paths
            let files: [URL] = stream == "stdout" ? [paths.stdoutLog(for: name)]
                : stream == "stderr" ? [paths.stderrLog(for: name)]
                : [paths.stdoutLog(for: name), paths.stderrLog(for: name)]
            let read = await Task.detached { () -> [String] in
                // Merge both files by their leading timestamp where there is one; keep file order otherwise.
                files.flatMap { LogReader.tail($0, lines: 200) }
            }.value
            let merged = stream == "Both" ? mergeByTime(read) : read
            if merged != lines { lines = merged }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func mergeByTime(_ lines: [String]) -> [String] {
        let stamped = lines.enumerated().map { index, line -> (String, Int, String) in
            let stamp = line.count >= 19 && line.dropFirst(4).first == "-" ? String(line.prefix(19)) : ""
            return (stamp, index, line)
        }
        guard stamped.contains(where: { !$0.0.isEmpty }) else { return lines }
        // Unstamped service output keeps its position after the last stamped line before it.
        var lastStamp = ""
        let keyed = stamped.map { stamp, index, line -> (String, Int, String) in
            if !stamp.isEmpty { lastStamp = stamp }
            return (lastStamp, index, line)
        }
        return Array(keyed.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2).suffix(200))
    }
}

struct StatTile: View {
    var label: String
    var value: String
    var sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            Text(sub.isEmpty ? " " : sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }
}

// MARK: - Readiness

struct ReadinessView: View {
    @Bindable var model: ShireModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Readiness").font(.title2.weight(.semibold))
                        Text("Will this Mac keep serving without you?").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.refresh(forceSystem: true) } label: { Label("Check again", systemImage: "arrow.clockwise") }
                }
                let checks = model.snapshot?.readiness ?? []
                if checks.isEmpty {
                    ProgressView("Checking…")
                }
                ForEach(checks, id: \.id) { check in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(check.level)).font(.title3).foregroundStyle(color(check.level)).frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(check.title).font(.headline)
                            Text(check.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let fix = check.fix {
                                Text("→ \(fix)").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
            }
            .padding(20)
        }
    }

    private func icon(_ level: ReadinessCheck.Level) -> String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .info: return "lock.circle"
        case .warn: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ level: ReadinessCheck.Level) -> Color {
        switch level {
        case .ok: return .green
        case .info: return .secondary
        case .warn: return .orange
        }
    }
}

// MARK: - Alerts

struct AlertsView: View {
    @Bindable var model: ShireModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Alerts").font(.title2.weight(.semibold))
                        Text("One notification per problem, and one when it recovers.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.notifications.post(AlertMessage(time: Date(), kind: .info, title: "Test alert",
                                                              body: "If you can read this, Shire’s alerts reach this Mac."))
                    } label: { Label("Send test alert", systemImage: "bell.badge") }
                }
                let incidents = model.snapshot?.incidents ?? []
                if !incidents.isEmpty {
                    Text("Open").font(.headline)
                    ForEach(incidents, id: \.key) { incident in
                        HStack {
                            StatusDot(color: .orange)
                            Text(incident.title)
                            Spacer()
                            Text("since \(Readiness.describe(Date().timeIntervalSince(incident.openedAt))) ago").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Recent").font(.headline)
                let alerts = model.snapshot?.recentAlerts ?? []
                if alerts.isEmpty { Text("No alerts yet.").foregroundStyle(.secondary) }
                ForEach(Array(alerts.enumerated()), id: \.offset) { _, alert in
                    HStack(alignment: .top, spacing: 10) {
                        StatusDot(color: alert.kind == .problem ? .red : alert.kind == .recovery ? .green : .gray).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.title).font(.body.weight(.semibold))
                            Text(alert.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(alert.time, format: .dateTime.weekday().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Text(model.snapshot?.config?.alerts.macos == false
                     ? "Notifications are off (alerts.macos: false); alerts are still recorded here."
                     : "Alert rules: crash loops (\(model.snapshot?.config?.alerts.crashLoop.description ?? "3 in 5m")), unhealthy for \(model.snapshot?.config?.alerts.unhealthyFor.description ?? "2m"), new readiness warnings, and downtime after a restart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}
