import AgentsAndReposCore
import SwiftUI

/// Compact PR row (titles are too long for square tiles).
struct PRRowView: View {
    let repoName: String
    let pr: PullRequest
    let actions: DashboardActions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ciColor)
                .frame(width: 7, height: 7)
            Text("\(repoName) #\(pr.number)")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Text(pr.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if pr.isDraft {
                Text("draft")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { actions.openURL(pr.url) }
        .help(pr.title)
    }

    private var ciColor: Color {
        switch pr.ci {
        case .pass: return .green
        case .fail: return .red
        case .pending: return .yellow
        case .none: return .secondary.opacity(0.4)
        }
    }
}
