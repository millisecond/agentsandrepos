import Foundation

public enum PRScope: String, Codable, Sendable {
    case mine
    case all
}

/// The dashboard sections that truncate to a recent-N view and can be
/// expanded; raw values are what `AppConfig.expandedSections` stores.
public enum DashboardSection: String, Codable, Sendable, CaseIterable {
    case prs, worktrees, repos
    /// The unified stack-ranked feed that replaces the three above.
    case ranked
    /// The collapsed "N repos can't connect" lump at the ranked feed's foot.
    case unreachable
}

public struct AppConfig: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var roots: [String] = ["~/Projects"]
    public var scanDepth: Int = 3
    public var fetchEnabled: Bool = true
    public var fetchIntervalMinutes: Int = 5
    public var autoFastForward: Bool = false
    public var prScope: PRScope = .mine
    public var prIntervalMinutes: Int = 5
    public var statusIntervalSeconds: Int = 45
    /// Repo paths hidden from the dashboard/menu (still scanned, shown in the ignored list).
    public var ignoredRepos: [String] = []
    /// Agent session ids hidden from the dashboard/menu.
    public var ignoredAgents: [String] = []
    /// Dashboard sections the user expanded past the recent-N cutoff.
    public var expandedSections: [String] = []
    /// On-device LLM one-liners on tiles (Apple Intelligence). On by default;
    /// ignored when the OS/model can't provide them.
    public var showLLMSummaries: Bool = true
    /// Daily release check against api.agentsandrepos.com (carries only the
    /// random install UUID). Off disables the request entirely.
    public var checkForUpdates: Bool = true

    public init() {}

    public func isSectionExpanded(_ section: DashboardSection) -> Bool {
        expandedSections.contains(section.rawValue)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, roots, scanDepth, fetchEnabled, fetchIntervalMinutes
        case autoFastForward, prScope, prIntervalMinutes, statusIntervalSeconds
        case ignoredRepos, ignoredAgents, expandedSections, showLLMSummaries
        case checkForUpdates
    }

    // Lenient decoding: any missing/invalid key falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        schemaVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? d.schemaVersion
        roots = (try? c.decodeIfPresent([String].self, forKey: .roots)) ?? d.roots
        scanDepth = (try? c.decodeIfPresent(Int.self, forKey: .scanDepth)) ?? d.scanDepth
        fetchEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .fetchEnabled)) ?? d.fetchEnabled
        fetchIntervalMinutes = (try? c.decodeIfPresent(Int.self, forKey: .fetchIntervalMinutes)) ?? d.fetchIntervalMinutes
        autoFastForward = (try? c.decodeIfPresent(Bool.self, forKey: .autoFastForward)) ?? d.autoFastForward
        prScope = (try? c.decodeIfPresent(PRScope.self, forKey: .prScope)) ?? d.prScope
        prIntervalMinutes = (try? c.decodeIfPresent(Int.self, forKey: .prIntervalMinutes)) ?? d.prIntervalMinutes
        statusIntervalSeconds = (try? c.decodeIfPresent(Int.self, forKey: .statusIntervalSeconds)) ?? d.statusIntervalSeconds
        ignoredRepos = (try? c.decodeIfPresent([String].self, forKey: .ignoredRepos)) ?? d.ignoredRepos
        ignoredAgents = (try? c.decodeIfPresent([String].self, forKey: .ignoredAgents)) ?? d.ignoredAgents
        expandedSections = (try? c.decodeIfPresent([String].self, forKey: .expandedSections)) ?? d.expandedSections
        showLLMSummaries = (try? c.decodeIfPresent(Bool.self, forKey: .showLLMSummaries)) ?? d.showLLMSummaries
        checkForUpdates = (try? c.decodeIfPresent(Bool.self, forKey: .checkForUpdates)) ?? d.checkForUpdates
    }
}
