import Foundation

public enum RemoteURLParser {
    /// Extracts "owner/repo" from a github.com remote URL. Returns nil for
    /// non-GitHub remotes. Handles:
    ///   git@github.com:owner/repo.git
    ///   https://github.com/owner/repo(.git)
    ///   ssh://git@github.com/owner/repo.git
    ///   git://github.com/owner/repo.git
    public static func githubOwnerRepo(from remote: String) -> String? {
        let s = remote.trimmingCharacters(in: .whitespacesAndNewlines)

        var rest: Substring?
        for prefix in [
            "git@github.com:", "ssh://git@github.com/", "ssh://github.com/",
            "https://github.com/", "http://github.com/", "git://github.com/",
        ] {
            if s.lowercased().hasPrefix(prefix) {
                rest = s.dropFirst(prefix.count)
                break
            }
        }
        // https://user@github.com/owner/repo
        if rest == nil, let range = s.range(of: "@github.com/"),
            s.lowercased().hasPrefix("https://") || s.lowercased().hasPrefix("http://")
        {
            rest = s[range.upperBound...]
        }
        guard var path = rest else { return nil }

        if path.hasSuffix(".git") { path = path.dropLast(4) }
        if path.hasSuffix("/") { path = path.dropLast() }
        let comps = path.split(separator: "/")
        guard comps.count >= 2, !comps[0].isEmpty, !comps[1].isEmpty else { return nil }
        return "\(comps[0])/\(comps[1])"
    }
}
