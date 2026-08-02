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

    public var id: Int { number }

    public init(
        number: Int, title: String, url: String, isDraft: Bool, author: String,
        headRefName: String, reviewDecision: String?, ci: CIStatus
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.author = author
        self.headRefName = headRefName
        self.reviewDecision = reviewDecision
        self.ci = ci
    }
}
