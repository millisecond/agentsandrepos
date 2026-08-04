import AgentsAndReposCore
import SwiftUI

/// Banner pinned to the top of the dashboard when a newer release is on
/// GitHub: version info plus the brew command to run, click-to-copy. No
/// in-app upgrade — the command kills and relaunches the app, which it
/// can't orchestrate on itself mid-run.
struct UpdateBanner: View {
    let version: String
    let actions: DashboardActions

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Update available: \(version) — you have \(Version.current)")
                    .font(.caption.weight(.semibold))
                Button {
                    actions.copyUpgradeCommand()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(UpdateCheck.upgradeCommand)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundStyle(copied ? Color.green : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help(copied ? "Copied" : "Copy command")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.55), lineWidth: 1.5)
        )
    }
}
