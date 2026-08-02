import AgentsAndReposCore
import SwiftUI

/// Square tile for one live Claude agent: status icon (pulsing while busy),
/// name, and where it's working.
struct AgentTileView: View {
    let state: AgentTileState
    /// LLM one-liner of the last user message.
    var userSummary: SummaryDisplay = SummaryDisplay()
    /// LLM one-liner of the last agent reply.
    var agentSummary: SummaryDisplay = SummaryDisplay()
    let actions: DashboardActions
    @State private var isHovering = false

    var body: some View {
        Tile(severity: state.severity) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top) {
                    if state.phase == .busy {
                        SpinningGear(color: Color(severity: state.severity))
                    } else {
                        Image(systemName: symbolName)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color(severity: state.severity))
                    }
                    Spacer()
                    if state.phase == .waiting {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
                // Both message summaries soak up the tile's flexible middle,
                // in the order the messages actually happened (latest last);
                // otherwise a spacer keeps the title block pinned down.
                if !userSummary.isEmpty || !agentSummary.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(orderedSummaries, id: \.icon) { line in
                            SummaryLine(display: line.display, lineLimit: 1, icon: line.icon)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 2)
                } else {
                    Spacer(minLength: 0)
                }
                Text(state.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(state.subtitle)
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
                TileIgnoreButton(help: "Ignore this agent") {
                    actions.ignoreAgent(sessionId: state.id)
                }
            }
        }
        .onHover { isHovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { actions.focusAgent(pid: state.pid, fallbackPath: state.path) }
        .contextMenu {
            Button("Focus Session") { actions.focusAgent(pid: state.pid, fallbackPath: state.path) }
            Button("Open in Finder") { actions.openInFinder(path: state.path) }
            Button("Open in Terminal") { actions.openInTerminal(path: state.path) }
            Button("Copy Path") { actions.copyPath(state.path) }
            Divider()
            Button("Ignore") { actions.ignoreAgent(sessionId: state.id) }
        }
        .help(
            "\(state.title) — \(state.statusLabel) · \(state.subtitle)"
                + (userSummary.text.map { " — asked: \($0)" } ?? "")
                + (agentSummary.text.map { " — agent: \($0)" } ?? ""))
    }

    /// Chronological: the earlier message first, the latest at the bottom.
    /// When the user spoke last the agent line shows its previous reply above.
    private var orderedSummaries: [(icon: String, display: SummaryDisplay)] {
        let user = (icon: "person.fill", display: userSummary)
        let agent = (icon: "sparkle", display: agentSummary)
        let ordered = state.task.userSpokeLast ? [agent, user] : [user, agent]
        return ordered.filter { !$0.display.isEmpty }
    }

    private var symbolName: String {
        switch state.phase {
        case .busy: return "gearshape.fill"
        case .waiting: return "pause.circle.fill"
        case .idle: return "moon.zzz.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}
