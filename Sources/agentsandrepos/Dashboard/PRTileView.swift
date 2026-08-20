import AgentsAndReposCore
import SwiftUI

/// Square tile for one open PR: CI/review state up top, the (often long)
/// title soaking the flexible middle, "repo #123" as the identity line.
struct PRTileView: View {
    let state: PRTileState
    let actions: DashboardActions
    @State private var isHovering = false

    var body: some View {
        Tile(severity: state.severity) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(severity: state.severity))
                    Spacer()
                    if state.isDraft {
                        Text("draft")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(.quaternary))
                    } else if state.ci != .none {
                        CIStatusDot(ci: state.ci)
                            .padding(.top, 2)
                    }
                }
                Text(state.title)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 2)
                Text(state.reference)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("⎇ \(state.branch) · \(state.author)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(state.statusLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color(severity: state.severity))
                    .lineLimit(1)
            }
            .padding(9)
        }
        .overlay(alignment: .topTrailing) {
            if isHovering {
                // "\(number)" pastes straight into `gh pr checkout`/`gh pr view`.
                TileCopyButton(help: "Copy PR number \(state.number)") {
                    actions.copyText(String(state.number))
                }
                .padding(4)
            }
        }
        .onHover { isHovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { actions.openURL(state.url) }
        .contextMenu {
            Button("Open on GitHub") { actions.openURL(state.url) }
            Button("Copy PR Number") { actions.copyText(String(state.number)) }
            Button("Copy URL") { actions.copyPath(state.url) }
            Button("Copy Branch Name") { actions.copyPath(state.branch) }
        }
        .help("\(state.reference) — \(state.title) · \(state.statusLabel)")
    }
}
