import Foundation

public struct PullRequest: Sendable, Equatable, Identifiable {
    public enum CIStatus: String, Sendable {
        case pass, fail, pending, none

        public var glyph: String {
            switch self {
            case .pass: return "✓"
            case .fail: return "✗"
            case .pending: return "◌"
            case .none: return ""
            }
        }
    }

    public let number: Int
    public let title: String
    public let url: String
    public let isDraft: Bool
    public let author: String
    public let headRefName: String
    public let reviewDecision: String?
    public let ci: CIStatus
    /// Names of the checks currently failing (empty unless ci == .fail) —
    /// "which check broke" without a trip to the browser.
    public let failingChecks: [String]
    /// Last activity on the PR (commits, comments, reviews) per GitHub.
    /// GitHub does NOT bump this when checks start or finish.
    public let updatedAt: Date?
    /// When the newest check in the rollup last started or completed — CI
    /// activity that `updatedAt` is blind to.
    public let ciUpdatedAt: Date?

    public var id: Int { number }

    /// Most recent thing that happened to the PR, CI included. A PR whose
    /// checks just went green is "recent" even if nobody pushed for hours.
    public var lastActivity: Date? {
        switch (updatedAt, ciUpdatedAt) {
        case let (u?, c?): return max(u, c)
        case let (u?, nil): return u
        case let (nil, c?): return c
        case (nil, nil): return nil
        }
    }

    public init(
        number: Int, title: String, url: String, isDraft: Bool, author: String,
        headRefName: String, reviewDecision: String?, ci: CIStatus,
        failingChecks: [String] = [], updatedAt: Date? = nil, ciUpdatedAt: Date? = nil
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.author = author
        self.headRefName = headRefName
        self.reviewDecision = reviewDecision
        self.ci = ci
        self.failingChecks = failingChecks
        self.updatedAt = updatedAt
        self.ciUpdatedAt = ciUpdatedAt
    }
}
