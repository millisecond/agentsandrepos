import Foundation

/// Reads branch-head oids straight from `.git` (loose refs, then
/// packed-refs) — zero subprocess spawns, so the status loop can consult
/// main's position on every tick without touching the spawn budget. The
/// packed-refs parse is cached by mtime+size (rule: no unconditional
/// re-reads); loose refs are single tiny files and read directly.
///
/// A value type owned by the engine actor: the cache mutates in actor
/// isolation, no locking needed.
public struct RefReader: Sendable {
    /// Local and origin heads of the repo's main branch.
    public struct MainRefs: Sendable, Equatable {
        /// Short branch name ("main"/"master", or whatever origin/HEAD says).
        public var branchName: String?
        public var localOid: String?
        public var remoteOid: String?

        public init(branchName: String? = nil, localOid: String? = nil, remoteOid: String? = nil) {
            self.branchName = branchName
            self.localOid = localOid
            self.remoteOid = remoteOid
        }
    }

    private var packedCache: [String: (mtime: Date, size: Int, refs: [String: String])] = [:]

    public init() {}

    /// Main-branch heads for the repo at `repoPath`. Prefers the branch
    /// origin/HEAD points at, falling back to main, then master.
    public mutating func mainRefs(repoPath: String) -> MainRefs {
        guard let gitDir = Self.gitCommonDir(repoPath: repoPath) else { return MainRefs() }

        var candidates = ["main", "master"]
        if let head = try? String(contentsOfFile: gitDir + "/refs/remotes/origin/HEAD", encoding: .utf8),
            let target = Self.symrefTarget(head),
            let name = target.split(separator: "/").last.map(String.init)
        {
            candidates.removeAll { $0 == name }
            candidates.insert(name, at: 0)
        }
        for name in candidates {
            let local = oid(ref: "refs/heads/\(name)", gitDir: gitDir)
            let remote = oid(ref: "refs/remotes/origin/\(name)", gitDir: gitDir)
            if local != nil || remote != nil {
                return MainRefs(branchName: name, localOid: local, remoteOid: remote)
            }
        }
        return MainRefs()
    }

    /// The directory holding shared refs: `.git` itself for a normal repo; for
    /// a linked worktree (`.git` is a "gitdir:" file) the commondir it points
    /// back to.
    static func gitCommonDir(repoPath: String) -> String? {
        let dotGit = repoPath + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit }

        guard let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
            let line = contents.split(separator: "\n").first, line.hasPrefix("gitdir:")
        else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") { gitdir = repoPath + "/" + gitdir }
        if let common = try? String(contentsOfFile: gitdir + "/commondir", encoding: .utf8) {
            var dir = common.trimmingCharacters(in: .whitespacesAndNewlines)
            if !dir.hasPrefix("/") { dir = gitdir + "/" + dir }
            return (dir as NSString).standardizingPath
        }
        return (gitdir as NSString).standardizingPath
    }

    /// Loose ref first (it shadows packed), then packed-refs. Follows up to
    /// two levels of "ref:" symrefs.
    mutating func oid(ref: String, gitDir: String, depth: Int = 0) -> String? {
        guard depth < 3 else { return nil }
        if let contents = try? String(contentsOfFile: gitDir + "/" + ref, encoding: .utf8) {
            let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if let target = Self.symrefTarget(line) {
                return oid(ref: target, gitDir: gitDir, depth: depth + 1)
            }
            if !line.isEmpty { return line }
        }
        return packedRefs(gitDir: gitDir)[ref]
    }

    private mutating func packedRefs(gitDir: String) -> [String: String] {
        let path = gitDir + "/packed-refs"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let mtime = attrs[.modificationDate] as? Date,
            let size = (attrs[.size] as? NSNumber)?.intValue
        else { return [:] }
        if let cached = packedCache[path], cached.mtime == mtime, cached.size == size {
            return cached.refs
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        let refs = Self.parsePackedRefs(text)
        packedCache[path] = (mtime, size, refs)
        return refs
    }

    /// "oid refname" lines; '#' comments and '^' peeled-tag lines skipped.
    static func parsePackedRefs(_ text: String) -> [String: String] {
        var refs: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#") || line.hasPrefix("^") { continue }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            refs[String(parts[1])] = String(parts[0])
        }
        return refs
    }

    private static func symrefTarget(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref: ") else { return nil }
        return trimmed.dropFirst("ref: ".count).trimmingCharacters(in: .whitespaces)
    }
}
