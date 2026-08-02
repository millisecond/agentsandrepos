import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    public var ok: Bool { exitCode == 0 && !timedOut }
}

/// Runs a subprocess with a hard timeout, capturing stdout/stderr.
/// Pipe reads happen on GCD threads (not the Swift cooperative pool) so a slow
/// child can never starve async work.
public enum ProcessRunner {

    private final class Context: @unchecked Sendable {
        let proc = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        private let lock = NSLock()
        private var _out = Data()
        private var _err = Data()
        private var _timedOut = false

        func setOut(_ d: Data) { lock.withLock { _out = d } }
        func setErr(_ d: Data) { lock.withLock { _err = d } }
        func markTimedOut() { lock.withLock { _timedOut = true } }
        var result: (out: Data, err: Data, timedOut: Bool) {
            lock.withLock { (_out, _err, _timedOut) }
        }
    }

    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        timeout: TimeInterval = 30
    ) async -> ProcessResult {
        let ctx = Context()
        return await withCheckedContinuation { (cont: CheckedContinuation<ProcessResult, Never>) in
            let proc = ctx.proc
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            if let environment { proc.environment = environment }
            if let currentDirectory {
                proc.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
            }
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = ctx.outPipe
            proc.standardError = ctx.errPipe

            let group = DispatchGroup()
            let readQueue = DispatchQueue.global(qos: .utility)
            group.enter()
            readQueue.async {
                ctx.setOut(ctx.outPipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
            group.enter()
            readQueue.async {
                ctx.setErr(ctx.errPipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }

            proc.terminationHandler = { p in
                let status = p.terminationStatus
                DispatchQueue.global(qos: .utility).async {
                    // If a grandchild inherited the pipe and lives on, don't wait forever.
                    _ = group.wait(timeout: .now() + 3)
                    let (out, err, timedOut) = ctx.result
                    cont.resume(returning: ProcessResult(
                        exitCode: status, stdout: out, stderr: err, timedOut: timedOut))
                }
            }

            do {
                try proc.run()
            } catch {
                proc.terminationHandler = nil
                // Unblock the reader threads.
                try? ctx.outPipe.fileHandleForWriting.close()
                try? ctx.errPipe.fileHandleForWriting.close()
                cont.resume(returning: ProcessResult(
                    exitCode: 127, stdout: Data(),
                    stderr: Data("\(error.localizedDescription)".utf8), timedOut: false))
                return
            }

            let pid = proc.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if ctx.proc.isRunning {
                    ctx.markTimedOut()
                    ctx.proc.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                        if ctx.proc.isRunning { kill(pid, SIGKILL) }
                    }
                }
            }
        }
    }
}
