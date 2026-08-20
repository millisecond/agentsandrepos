import AgentsAndReposCore
import SwiftUI

/// Full-width row for one live Claude agent: status icon (pulsing while
/// busy), name and location on the header line, then the last user prompt
/// and agent reply with room to actually read them.
struct AgentTileView: View {
    let state: AgentTileState
    /// LLM one-liner of the last user message.
    var userSummary: SummaryDisplay = SummaryDisplay()
    /// LLM one-liner of the last agent reply.
    var agentSummary: SummaryDisplay = SummaryDisplay()
    let actions: DashboardActions
    @State private var isHovering = false
    @Environment(\.dashboardLive) private var live
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // Filled badge around the robot: the one leading element in the
            // dashboard with a solid tinted block behind it, so agent rows
            // can't be mistaken for the outline-glyph ranked rows below.
            iconView
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.18)))
                .overlay(badgeOutline)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(state.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(state.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // Hover control draws OVER the spacer's empty gap (an
                    // overlay, not a layout sibling — the button is taller
                    // than the text line, so participating in layout would
                    // grow the row on hover). Status and bars never move.
                    Spacer(minLength: 8)
                        .overlay(alignment: .trailing) {
                            if isHovering {
                                TileIgnoreButton(help: "Ignore this agent") {
                                    actions.ignoreAgent(sessionId: state.id)
                                }
                            }
                        }
                    Text(state.statusLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    AgentActivityBars(
                        levels: state.activity,
                        color: tint)
                }
                ForEach(orderedSummaries, id: \.icon) { line in
                    SummaryLine(display: line.display, lineLimit: line.lines, icon: line.icon)
                }
            }
        }
        .modifier(RowChrome(severity: state.severity, tint: tileTint, style: .agent))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
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

    /// The badge border. While the agent is actually doing something (busy,
    /// or running a shell command) a tint segment orbits the outline —
    /// slower than the CI spinner so a row of working agents doesn't strobe.
    /// Same gating as every continuous animation: static while the popover
    /// is hidden or reduce-motion is on.
    @ViewBuilder
    private var badgeOutline: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if isWorking, live, !reduceMotion {
            OrbitingOutline(shape: shape, color: tint, perimeter: 99, lineWidth: 1, duration: 2)
        } else {
            shape.strokeBorder(tint.opacity(0.35), lineWidth: 1)
        }
    }

    private var isWorking: Bool {
        state.phase == .busy || state.phase == .shell
    }

    @ViewBuilder
    private var iconView: some View {
        if state.phase == .busy {
            BusyAgentIcon(color: tint)
        } else if let agentImage {
            AgentIconImage(image: agentImage, color: tint)
        } else {
            // Shell means a command is executing right now, so the terminal
            // glyph pulses like the other active states. Gated the same way
            // as BusyAgentIcon: no repeating effect while the popover is
            // hidden or reduce-motion is on.
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .symbolEffect(
                    .pulse, options: .repeating,
                    isActive: state.phase == .shell && live && !reduceMotion)
        }
    }

    /// Chronological: the earlier message first, the latest at the bottom.
    /// When the user spoke last the agent line shows its previous reply
    /// above. The prompt gets an extra line — it's the thing you're trying
    /// to tell sessions apart by. Full-width rows wrap far less than the
    /// old grid tiles did, so the allowances stay small to keep rows short.
    private var orderedSummaries: [(icon: String, lines: Int, display: SummaryDisplay)] {
        let user = (icon: "person.fill", lines: 2, display: userSummary)
        let agent = (icon: "sparkle", lines: 1, display: agentSummary)
        let ordered = state.task.userSpokeLast ? [agent, user] : [user, agent]
        return ordered.filter { !$0.display.isEmpty }
    }

    /// Phases without a TileSeverity of their own: shell renders teal
    /// (between busy-blue and idle-gray); unknown renders indigo so an
    /// unrecognized status is visibly not the same thing as asleep-gray.
    private var tileTint: Color? {
        switch state.phase {
        case .shell: return .teal
        case .unknown: return .indigo
        case .idle, .busy, .waiting: return nil
        }
    }

    private var tint: Color {
        tileTint ?? Color(severity: state.severity)
    }

    /// The shared robot glyphs where a variant exists, so the rows match the
    /// menu bar; shell/unknown keep their own SF symbols (distinct states the
    /// robot family doesn't cover).
    private var agentImage: NSImage? {
        switch state.phase {
        case .busy: return AgentIcon.busy
        case .waiting: return AgentIcon.waiting
        case .idle: return AgentIcon.idle
        case .shell, .unknown: return nil
        }
    }

    private var symbolName: String {
        switch state.phase {
        case .shell: return "terminal.fill"
        case .unknown: return "questionmark.circle.fill"
        case .busy, .waiting, .idle: return ""
        }
    }
}
