import Foundation

public enum PRScope: String, Codable, Sendable {
    case mine
    case all
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
    /// Auto-hide repos with no activity (commits or file edits) for this many
    /// days — unless they have live agents or open PRs. 0 disables.
    public var autoHideStaleDays: Int = 30
    /// Repo paths hidden from the dashboard/menu (still scanned, shown in the ignored list).
    public var ignoredRepos: [String] = []
    /// Repo paths exempt from stale auto-hiding (the user un-hid them).
    public var staleExemptRepos: [String] = []
    /// Agent session ids hidden from the dashboard/menu.
    public var ignoredAgents: [String] = []
    /// On-device LLM one-liners on tiles (Apple Intelligence). On by default;
    /// ignored when the OS/model can't provide them.
    public var showLLMSummaries: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, roots, scanDepth, fetchEnabled, fetchIntervalMinutes
        case autoFastForward, prScope, prIntervalMinutes, statusIntervalSeconds
        case autoHideStaleDays, ignoredRepos, staleExemptRepos, ignoredAgents, showLLMSummaries
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
        autoHideStaleDays = (try? c.decodeIfPresent(Int.self, forKey: .autoHideStaleDays)) ?? d.autoHideStaleDays
        ignoredRepos = (try? c.decodeIfPresent([String].self, forKey: .ignoredRepos)) ?? d.ignoredRepos
        staleExemptRepos = (try? c.decodeIfPresent([String].self, forKey: .staleExemptRepos)) ?? d.staleExemptRepos
        ignoredAgents = (try? c.decodeIfPresent([String].self, forKey: .ignoredAgents)) ?? d.ignoredAgents
        showLLMSummaries = (try? c.decodeIfPresent(Bool.self, forKey: .showLLMSummaries)) ?? d.showLLMSummaries
    }
}
