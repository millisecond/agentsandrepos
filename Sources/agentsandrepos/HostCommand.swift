import Foundation

/// Runs helper CLIs (tmux, wezterm) synchronously with a short timeout.
/// Outputs are tiny (pane/client listings), so read-after-exit is safe; a
/// child that somehow fills the pipe buffer just hits the timeout and is
/// terminated.
enum HostCommand {

    /// First executable candidate path wins; otherwise fall back to
    /// `/usr/bin/env <name>` for whatever PATH the app inherited.
    @discardableResult
    static func run(
        candidates: [String], name: String, args: [String], timeout: TimeInterval = 3
    ) -> String? {
        let exe = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe ?? "/usr/bin/env")
        proc.arguments = exe != nil ? args : [name] + args
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do { try proc.run() } catch { return nil }
        guard done.wait(timeout: .now() + timeout) != .timedOut else {
            proc.terminate()
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
