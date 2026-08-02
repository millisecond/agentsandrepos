import Foundation

/// Scans configured root folders for git repos (a `.git` dir or file).
public enum RepoDiscovery {
    static let skipNames: Set<String> = [
        "node_modules", ".build", "Pods", "DerivedData", "vendor", "dist", "build",
    ]

    public static func discover(roots: [String], maxDepth: Int) -> [Repo] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [Repo] = []

        for rootRaw in roots {
            let root = (rootRaw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }
            walk(dir: root, root: root, depth: 0, maxDepth: max(1, maxDepth), seen: &seen, out: &out)
        }
        return out.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func walk(
        dir: String, root: String, depth: Int, maxDepth: Int,
        seen: inout Set<String>, out: inout [Repo]
    ) {
        let fm = FileManager.default
        if isRepo(dir) {
            let canonical = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
            if seen.insert(canonical).inserted {
                out.append(Repo(
                    path: canonical,
                    name: (dir as NSString).lastPathComponent,
                    root: root,
                    isRoot: depth == 0))
            }
            return  // never descend into a repo
        }
        guard depth < maxDepth else { return }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for entry in entries {
            if entry.hasPrefix(".") || skipNames.contains(entry) { continue }
            let path = dir + "/" + entry
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            walk(dir: path, root: root, depth: depth + 1, maxDepth: maxDepth, seen: &seen, out: &out)
        }
    }

    static func isRepo(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/.git")
    }
}
