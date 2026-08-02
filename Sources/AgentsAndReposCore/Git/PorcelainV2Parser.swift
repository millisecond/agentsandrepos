import Foundation

/// Parses `git status --porcelain=v2 --branch` output.
public enum PorcelainV2Parser {
    /// Enough for an LLM job description without bloating every snapshot.
    static let maxChangedPaths = 20

    public static func parse(_ text: String) -> GitState {
        var state = GitState()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.oid ") {
                let oid = String(line.dropFirst("# branch.oid ".count))
                state.headOid = oid == "(initial)" ? nil : oid
            } else if line.hasPrefix("# branch.head ") {
                let name = String(line.dropFirst("# branch.head ".count))
                if name == "(detached)" {
                    state.detached = true
                } else {
                    state.branch = name
                }
            } else if line.hasPrefix("# branch.upstream ") {
                state.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") {
                        state.ahead = Int(part.dropFirst()) ?? 0
                    } else if part.hasPrefix("-") {
                        state.behind = Int(part.dropFirst()) ?? 0
                    }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                state.dirty += 1
                addPath(changedPath(of: line), to: &state)
            } else if line.hasPrefix("? ") {
                state.untracked += 1
                addPath(String(line.dropFirst(2)), to: &state)
            }
        }
        return state
    }

    private static func addPath(_ path: String?, to state: inout GitState) {
        guard let path, !path.isEmpty, state.changedPaths.count < maxChangedPaths else { return }
        state.changedPaths.append(path)
    }

    /// Path field of a `1`/`2`/`u` entry. Fixed field counts per line type;
    /// the path is everything after them (it may contain spaces). Rename (`2`)
    /// entries carry `path<TAB>origPath` — keep the new path.
    static func changedPath(of line: Substring) -> String? {
        let fieldCount: Int
        switch line.first {
        case "1": fieldCount = 8
        case "2": fieldCount = 9
        case "u": fieldCount = 10
        default: return nil
        }
        let fields = line.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
        guard fields.count > fieldCount else { return nil }
        return String(fields[fieldCount].split(separator: "\t")[0])
    }
}
