import AppKit
import SwiftUI
import TenderCore

extension TenderSnapshot.Service.Tone {
    var color: Color {
        switch self {
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        case .off: return .gray
        }
    }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// The popover under the menu bar icon: is my little Mac server okay, and the one thing to do about it.
struct MenuContent: View {
    @Bindable var model: TenderModel
    @State private var loginItem = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 6)
            services
            system
            Divider().padding(.vertical, 6)
            actions
            if let outcome = model.lastOutcome {
                Divider().padding(.vertical, 6)
                OutcomeLine(outcome: outcome)
            }
            Divider().padding(.vertical, 6)
            footer
        }
        .padding(10)
        .frame(width: 350)
        .onAppear { model.refresh() }
    }

    private var overallColor: Color {
        switch model.overall {
        case .healthy: return .green
        case .attention: return .orange
        case .notRunning: return .gray
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: overallColor, size: 12).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.headline).font(.system(size: 16, weight: .bold))
                Text(model.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 6)
    }

    private var services: some View {
        ForEach(model.snapshot?.services ?? []) { service in
            MenuServiceRow(service: service, busy: model.busy.contains(service.name)) {
                model.selection = .service(service.name)
                model.showWindow?()
            } restart: {
                model.restart(service.name)
            }
        }
    }

    @ViewBuilder
    private var system: some View {
        if let rows = model.snapshot?.system?.rows {
            ForEach(rows.filter { $0.name == "tailscale" || $0.name == "keep-awake" }, id: \.name) { row in
                HStack(spacing: 10) {
                    StatusDot(color: row.level == .ok ? .green : row.level == .warn ? .orange : .gray, size: 9)
                    Text(row.name == "keep-awake" ? "Keep Mac awake" : "Tailscale").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(row.value).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let broken = model.snapshot?.services.first(where: { $0.tone == .bad || $0.tone == .warn }) {
                MenuButton(title: "View \(broken.name)…", bold: true) {
                    model.selection = .service(broken.name)
                    model.showWindow?()
                }
            }
            MenuButton(title: "Open Tender", shortcut: "⌘O") { model.showWindow?() }
            MenuButton(title: "Open config.yaml") {
                model.selection = .config
                model.showWindow?()
            }
            MenuButton(title: model.busy.contains("apply") ? "Applying…" : "Apply changes") { model.apply() }
                .disabled(model.busy.contains("apply"))
            MenuButton(title: "Readiness", trailing: readinessTrailing, trailingColor: model.readinessWarnings.isEmpty ? .secondary : .orange) {
                model.selection = .readiness
                model.showWindow?()
            }
            MenuButton(title: "Alerts", trailing: model.snapshot?.recentAlerts.first.map { "last \(relative($0.time))" } ?? "none yet") {
                model.selection = .alerts
                model.showWindow?()
            }
        }
    }

    private var readinessTrailing: String {
        let count = model.readinessWarnings.count
        return count == 0 ? "ready" : "\(count) warning\(count == 1 ? "" : "s")"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Open at login", isOn: $loginItem)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .onChange(of: loginItem) { _, value in LoginItem.set(value) }
            MenuButton(title: "Quit Tender menu", shortcut: "⌘Q") { NSApp.terminate(nil) }
            Text("Quitting the menu leaves your services and tender-agent running.")
                .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 10)
        }
    }

    private func relative(_ date: Date) -> String {
        Readiness.describe(Date().timeIntervalSince(date)) + " ago"
    }
}

struct MenuServiceRow: View {
    var service: TenderSnapshot.Service
    var busy: Bool
    var open: () -> Void
    var restart: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                StatusDot(color: service.tone.color, size: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.name).font(.system(size: 13, weight: .semibold))
                    Text(service.detailText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if busy {
                    ProgressView().controlSize(.small)
                } else if hovering, !service.config.isExternal {
                    Button("Restart", action: restart).controlSize(.small)
                } else {
                    Text(service.stateText).font(.caption.weight(.semibold)).foregroundStyle(service.tone.color)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuButton: View {
    var title: String
    var shortcut: String? = nil
    var trailing: String? = nil
    var trailingColor: Color = .secondary
    var bold = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13, weight: bold ? .semibold : .regular))
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(trailingColor) }
                if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.accentColor.opacity(0.18) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct OutcomeLine: View {
    var outcome: CommandOutcome

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(outcome.succeeded ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.title + (outcome.succeeded ? " — done" : " — failed")).font(.caption.weight(.semibold))
                if !outcome.succeeded || outcome.output.count < 120 {
                    Text(outcome.output.split(separator: "\n").suffix(3).joined(separator: "\n"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(4)
                }
            }
        }
        .padding(.horizontal, 10)
    }
}
