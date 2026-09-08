import Foundation

public enum ConfigStore {
    public static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/agentsandrepos/config.json")
    }

    /// True until the config file exists — i.e. the app has never run before.
    /// Must be checked before `load()`, which creates the default file.
    public static func isFirstRun(url: URL = configURL) -> Bool {
        !FileManager.default.fileExists(atPath: url.path)
    }

    /// Loads config, creating a default file on first run. A corrupt file is left
    /// untouched and defaults are used for the session.
    public static func load(from url: URL = configURL) -> AppConfig {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            let config = AppConfig()
            save(config, to: url)
            return config
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            FileHandle.standardError.write(Data("agentsandrepos: could not parse \(url.path): \(error)\n".utf8))
            return AppConfig()
        }
    }

    public static func save(_ config: AppConfig, to url: URL = configURL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("agentsandrepos: could not save config: \(error)\n".utf8))
        }
    }
}
