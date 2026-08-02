import Foundation

/// flock-based single-instance guard. The fd is held for the process lifetime.
public enum SingleInstanceLock {
    private nonisolated(unsafe) static var fd: Int32 = -1

    public static var defaultPath: String {
        NSHomeDirectory() + "/.config/agentsandrepos/app.lock"
    }

    public static func acquire(path: String = defaultPath) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let openedFD = open(path, O_CREAT | O_RDWR, 0o644)
        guard openedFD >= 0 else { return false }
        if flock(openedFD, LOCK_EX | LOCK_NB) != 0 {
            close(openedFD)
            return false
        }
        fd = openedFD
        return true
    }
}
