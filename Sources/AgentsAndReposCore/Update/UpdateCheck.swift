import Foundation

/// Pure logic for the "new release available?" check: release-tag parsing and
/// a dotted-version compare. Networking lives in the app target so this stays
/// unit-testable.
public enum UpdateCheck {
    /// Endpoint the app polls for the latest release. Doesn't exist yet — the
    /// check fails silently until the API is stood up, which is intentional.
    /// Expected response shape matches GitHub's `releases/latest`:
    /// `{"tag_name": "v0.2.0"}`.
    ///
    /// `installID` is the random per-install UUID (see `InstallID` in the app
    /// target), sent so the server can count installs; it carries no personal
    /// information.
    public static func latestReleaseURL(installID: String) -> URL {
        var components = URLComponents(
            string: "https://api.agentsandrepos.com/v1/releases/latest")!
        components.queryItems = [URLQueryItem(name: "install_id", value: installID)]
        return components.url!
    }

    /// Command a brew user runs to move to the advertised release. The
    /// upgrade swaps the .app on disk but leaves the old binary running (and
    /// holding the single-instance lock), so the command also relaunches.
    public static let upgradeCommand =
        "brew upgrade --cask agentsandrepos && killall agentsandrepos && open -a \"Agents & Repos\""

    /// Bare version from a release `tag_name` ("v0.2.0" → "0.2.0").
    /// Nil when the tag doesn't start with a version number.
    public static func version(fromTag tag: String) -> String? {
        var s = Substring(tag.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        guard let first = s.first, first.isNumber else { return nil }
        return String(s)
    }

    /// True when `latest` is strictly newer than `current`. Compares
    /// dot-separated numeric components; missing components count as 0 and a
    /// pre-release suffix ("0.2.0-beta1") compares equal to its base.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = numericComponents(latest)
        let b = numericComponents(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Parses a GitHub `releases/latest` response and returns the advertised
    /// version only when it's newer than `current`.
    public static func availableUpdate(fromReleaseJSON data: Data, current: String) -> String? {
        struct Release: Decodable {
            let tag_name: String
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
            let latest = version(fromTag: release.tag_name),
            isNewer(latest, than: current)
        else { return nil }
        return latest
    }

    private static func numericComponents(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
