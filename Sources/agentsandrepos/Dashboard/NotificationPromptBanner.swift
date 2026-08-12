import AgentsAndReposCore
import SwiftUI

/// One-time opt-in banner at the top of the dashboard. Enable turns
/// notifications on (and triggers the macOS permission prompt); Dismiss hides
/// it for good; untouched, it ages out a day after first shown
/// (`NotificationPrompt`). Either way, Settings keeps the switch.
struct NotificationPromptBanner: View {
    let actions: DashboardActions

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "bell.badge")
                .font(.system(size: 15))
                .foregroundStyle(.blue)
            Text(
                "Get important local notifications about Git builds/actions and permission requests"
            )
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Dismiss") { actions.dismissNotificationsPrompt() }
                .buttonStyle(.borderless)
                .controlSize(.small)
            Button("Enable") { actions.enableNotifications() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.blue.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.45), lineWidth: 1.5)
        )
        .onAppear { actions.noteNotificationsPromptShown() }
    }
}
