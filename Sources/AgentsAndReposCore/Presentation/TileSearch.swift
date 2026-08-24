import Foundation

/// A tokenized dashboard search query. Matching is case- and
/// diacritic-insensitive substring search; multiple words AND together, each
/// free to hit a different field — "auth widgets" finds the widgets repo whose
/// agent is working on auth. An empty (or all-whitespace) query matches
/// everything.
public struct SearchQuery: Sendable, Equatable {
    public let tokens: [String]

    public init(_ raw: String) {
        self.tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public var isEmpty: Bool { tokens.isEmpty }

    /// True when every token appears in at least one of the fields.
    public func matches(_ fields: [String]) -> Bool {
        tokens.allSatisfy { token in
            fields.contains {
                $0.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}

extension AgentTileState {
    /// Name, location, status, path, and the transcript tail — the "what was
    /// that agent doing" text is usually what the user remembers. Reaches
    /// the whole capped history, not just the two headline messages the
    /// tile shows.
    public var searchFields: [String] {
        var fields = [title, subtitle, statusLabel, path]
        if let m = task.lastUserMessage { fields.append(m) }
        if let m = task.lastAgentMessage { fields.append(m) }
        fields += task.history.map(\.text)
        return fields
    }

    public func matches(_ query: SearchQuery) -> Bool { query.matches(searchFields) }
}

extension RepoTileState {
    /// Identity plus in-flight context: branch, changed file paths, the tasks
    /// of agents working here, failing-PR title, and workflow-run names.
    public var searchFields: [String] {
        var fields = [name, branch, path]
        if let githubRepo { fields.append(githubRepo) }
        if let failingPR { fields.append(failingPR.title) }
        fields += agentTasks
        fields += changedPaths
        for run in runs {
            fields.append(run.workflowName)
            fields.append(run.title)
        }
        return fields
    }

    public func matches(_ query: SearchQuery) -> Bool { query.matches(searchFields) }
}

extension PRTileState {
    public var searchFields: [String] {
        [reference, title, repoName, author, branch, statusLabel, url]
    }

    public func matches(_ query: SearchQuery) -> Bool { query.matches(searchFields) }
}

extension RankedTile {
    public func matches(_ query: SearchQuery) -> Bool {
        switch self {
        case .repo(let r): return r.matches(query)
        case .pr(let p): return p.matches(query)
        }
    }
}

extension Snapshot {
    /// Agent tiles filtered to the query; same ordering as `agentTiles`.
    public func agentTiles(matching query: SearchQuery) -> [AgentTileState] {
        query.isEmpty ? agentTiles : agentTiles.filter { $0.matches(query) }
    }

    /// The ranked feed under a search: every match shown (no recent-N cut)
    /// and quiet-unreachable repos back in the pool — a search is a lookup,
    /// so nothing the query names may hide behind a lump or a "show more".
    public func rankedSection(now: Date = Date(), matching query: SearchQuery)
        -> TileSection<RankedTile>
    {
        guard !query.isEmpty else { return rankedSection(now: now) }
        let all = rankedTiles(now: now, includeUnreachable: true).filter { $0.matches(query) }
        return TileSection(all: all, isExpanded: true, limit: Self.rankedRecentLimit)
    }
}
