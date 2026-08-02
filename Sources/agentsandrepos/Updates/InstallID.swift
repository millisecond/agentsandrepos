import Foundation

/// Random UUID identifying this install, generated on first use and persisted
/// in UserDefaults. Sent with update checks so the server can count installs;
/// never derived from anything on the machine.
enum InstallID {
    private static let defaultsKey = "installID"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: defaultsKey) {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: defaultsKey)
        return id
    }
}
