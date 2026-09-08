import Foundation

/// On-disk home for the planner's run beliefs, next to the config file.
/// Written only when a run finishes (rare), read once at launch.
public enum BeliefStore {
    public static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/agentsandrepos/notification-beliefs.json")
    }

    public static func load(from url: URL = url) -> [String: RunBelief] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([String: RunBelief].self, from: data)
        } catch {
            FileHandle.standardError.write(
                Data("agentsandrepos: could not parse \(url.path): \(error)\n".utf8))
            return [:]
        }
    }

    public static func save(_ beliefs: [String: RunBelief], to url: URL = url) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(beliefs).write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(
                Data("agentsandrepos: could not save beliefs: \(error)\n".utf8))
        }
    }
}
