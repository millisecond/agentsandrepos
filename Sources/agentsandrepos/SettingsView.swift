import AgentsAndReposCore
import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var config: AppConfig
    @State private var launchAtLogin = LaunchAtLogin.isAvailable && LaunchAtLogin.isEnabled
    @ObservedObject var summaries: SummaryService
    let onTestNotification: () -> Void
    let onSave: (AppConfig) -> Void

    init(
        config: AppConfig, summaries: SummaryService,
        onTestNotification: @escaping () -> Void = {},
        onSave: @escaping (AppConfig) -> Void
    ) {
        _config = State(initialValue: config)
        self.summaries = summaries
        self.onTestNotification = onTestNotification
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Repository Folders") {
                if config.roots.isEmpty {
                    Text("No folders configured").foregroundStyle(.secondary)
                }
                ForEach(config.roots, id: \.self) { root in
                    HStack {
                        Text(root)
                        Spacer()
                        Button(role: .destructive) {
                            config.roots.removeAll { $0 == root }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") { addFolder() }
                Stepper("Scan depth: \(config.scanDepth)", value: $config.scanDepth, in: 1...5)
            }

            Section("Git") {
                Toggle("Auto-fetch in background", isOn: $config.fetchEnabled)
                Stepper(
                    "Fetch every \(config.fetchIntervalMinutes) min",
                    value: $config.fetchIntervalMinutes, in: 1...60)
                Toggle("Fast-forward clean repos", isOn: $config.autoFastForward)
                Text("Only repos that are clean and strictly behind their upstream. Never force-pushes, resets, or touches a repo an agent is working in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(
                    "Refresh status every \(config.statusIntervalSeconds)s",
                    value: $config.statusIntervalSeconds, in: 10...300, step: 5)
            }

            Section("AI Summaries") {
                switch SummaryAvailability.current {
                case .available:
                    Toggle("Show LLM Summaries", isOn: $config.showLLMSummaries)
                    Text("One-line tile summaries generated on-device with Apple Intelligence. Nothing leaves this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let s = summaries.stats {
                        Text(String(
                            format: "%d generations · avg %.0f ms · last %.0f ms · max %.0f ms",
                            s.count, s.avgMs, s.lastMs, s.maxMs))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                case .unavailable(let reason):
                    Toggle("Show LLM Summaries", isOn: .constant(false))
                        .disabled(true)
                    Text("Summaries not Available — \(reason).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Notifications") {
                Toggle("Enable local notifications", isOn: $config.notificationsEnabled)
                if config.notificationsEnabled {
                    Toggle("Git builds/actions finish", isOn: $config.notifyGitActions)
                    Toggle(
                        "Agent waiting on you for over 5 minutes",
                        isOn: $config.notifyWaitingAgents)
                }
                Text("Delivered locally via macOS Notification Center — nothing leaves this Mac. Sound and banner style are managed in System Settings → Notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Send Test Notification") { onTestNotification() }
            }

            Section("GitHub Pull Requests") {
                Picker("Show", selection: $config.prScope) {
                    Text("My PRs").tag(PRScope.mine)
                    Text("All PRs").tag(PRScope.all)
                }
                .pickerStyle(.segmented)
                Stepper(
                    "Refresh every \(config.prIntervalMinutes) min",
                    value: $config.prIntervalMinutes, in: 1...60)
            }

            Section {
                if LaunchAtLogin.isAvailable {
                    Toggle("Start at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in
                            LaunchAtLogin.set(enabled: on)
                        }
                } else {
                    Text("Start at login is available when running the installed app (`brew install --cask agentsandrepos`), not a bare build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Save") { onSave(config) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            var path = url.path
            let home = NSHomeDirectory()
            if path.hasPrefix(home) { path = "~" + path.dropFirst(home.count) }
            if !config.roots.contains(path) { config.roots.append(path) }
        }
    }
}
