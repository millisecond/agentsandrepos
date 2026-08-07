import Foundation

/// One GitHub Actions workflow run at the repo level (deploys, scheduled jobs,
/// pushes). Runs triggered by `pull_request` events are excluded upstream —
/// those already surface as PR CI status.
public struct WorkflowRun: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable {
        /// queued / in_progress / waiting
        case running
        case passed
        case failed
        /// cancelled, skipped, neutral — shown muted, never drives severity
        case other

        public var glyph: String {
            switch self {
            case .running: return "◌"
            case .passed: return "✓"
            case .failed: return "✗"
            case .other: return "–"
            }
        }
    }

    public let id: Int
    public let workflowName: String
    /// The run's display title (usually the commit subject or dispatch title).
    public let title: String
    public let branch: String
    /// Trigger event: push, workflow_dispatch, schedule, release, …
    public let event: String
    public let state: State
    public let url: String
    public let updatedAt: Date?

    public init(
        id: Int, workflowName: String, title: String, branch: String, event: String,
        state: State, url: String, updatedAt: Date? = nil
    ) {
        self.id = id
        self.workflowName = workflowName
        self.title = title
        self.branch = branch
        self.event = event
        self.state = state
        self.url = url
        self.updatedAt = updatedAt
    }

    /// fail > running > pass > other — mirror of `RepoTileState.worstCI`.
    public static func worstState(of runs: [WorkflowRun]) -> State? {
        var worst: State? = nil
        for run in runs {
            switch (run.state, worst) {
            case (.failed, _): return .failed
            case (.running, _) where worst != .failed: worst = .running
            case (.passed, .other), (.passed, .none): worst = .passed
            case (.other, .none): worst = .other
            default: break
            }
        }
        return worst
    }
}
