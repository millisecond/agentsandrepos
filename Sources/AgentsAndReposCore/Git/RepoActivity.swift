import Foundation

/// Derives "when was this repo last worked on" from the HEAD commit time plus
/// the mtimes of currently changed/untracked files, so a repo abandoned
/// mid-edit ages out just like a committed-and-forgotten one.
public enum RepoActivity {
    public static func lastActivity(
        repoPath: String, commitDate: Date?, changedPaths: [String]
    ) -> Date? {
        var latest = commitDate
        let fm = FileManager.default
        for rel in changedPaths {
            let full = repoPath + "/" + rel
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                let mtime = attrs[.modificationDate] as? Date
            else { continue }
            if latest == nil || mtime > latest! { latest = mtime }
        }
        return latest
    }
}
