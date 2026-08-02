import AgentsAndReposCore
import SwiftUI

/// Bottom bar: summary text + refresh button + gear menu with the controls
/// the legacy dropdown offered.
struct FooterBar: View {
    let snapshot: Snapshot
    let actions: DashboardActions

    var body: some View {
        HStack(spacing: 10) {
            summary
            Spacer(minLength: 8)
            Button {
                actions.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh Now (⌘R)")

            Menu {
                Toggle(
                    "Show Only My PRs",
                    isOn: Binding(
                        get: { snapshot.config.prScope == .mine },
                        set: { _ in actions.togglePRScope() }))
                Toggle(
                    "Auto-Fetch (every \(snapshot.config.fetchIntervalMinutes)m)",
                    isOn: Binding(
                        get: { snapshot.config.fetchEnabled },
                        set: { _ in actions.toggleAutoFetch() }))
                Divider()
                Button("Settings…") { actions.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Quit \(AppInfo.displayName)") { actions.quit() }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: some View {
        let repos = snapshot.visibleRepos
        let clean = repos.filter { !$0.needsAttention }.count
        var text = Text("\(repos.count) repos · \(clean) clean")
        if let fetched = snapshot.lastFetchAt {
            text = text + Text(" · fetched ") + Text(fetched, style: .relative) + Text(" ago")
        }
        return text
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
