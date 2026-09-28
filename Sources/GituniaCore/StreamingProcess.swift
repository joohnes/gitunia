import Foundation
import Synchronization

/// Like `ProcessRunner.run`, but hands stderr to `onStderr` as it arrives (for `git clone
/// --progress`) and discards stdout. Cancelling the calling task SIGTERMs the child. Only the pid
/// (a plain `Int32`) crosses into the cancellation handler, guarded by a `Mutex` together with the
/// cancelled flag, so a cancel racing the launch either prevents it or kills what was launched.
public enum StreamingProcess {
    private final class Handle: Sendable {
        struct State { var cancelled = false; var pid: pid_t = 0; var errPipe: Pipe? }
        let state = Mutex(State())

        /// Same grace period as `ProcessRunner`: SIGTERM first, then after a fixed 2s, SIGKILL
        /// whatever's left and force-close the stderr read end so a grandchild (ssh, a credential
        /// helper) still holding the write end open can't block the drain loop forever.
        func cancel() {
            let pid = state.withLock { s -> pid_t in
                s.cancelled = true
                if s.pid > 0 { kill(s.pid, SIGTERM) }
                return s.pid
            }
            guard pid > 0 else { return }
            Thread {
                Thread.sleep(forTimeInterval: 2)
                let (stillThere, errPipe) = self.state.withLock { s in (s.pid == pid, s.errPipe) }
                if stillThere { kill(pid, SIGKILL) }
                try? errPipe?.fileHandleForReading.close()
            }.start()
        }
    }

    public static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String] = [:],
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        let handle = Handle()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = currentDirectory
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
                process.standardOutput = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                let errPipe = Pipe()
                process.standardError = errPipe
                try handle.state.withLock { s in
                    if s.cancelled { throw CancellationError() }
                    try process.run()
                    s.pid = process.processIdentifier
                    s.errPipe = errPipe
                }
                var errData = Data()
                // `read(upToCount:)`, not the legacy `availableData`: on cancellation `Handle.cancel()`
                // closes this read end past its grace period, and the legacy API raises an
                // uncatchable ObjC exception on that rather than throwing.
                while let chunk = try? errPipe.fileHandleForReading.read(upToCount: Int.max), !chunk.isEmpty {
                    errData.append(chunk)
                    onStderr(String(decoding: chunk, as: UTF8.self))
                }
                process.waitUntilExit()
                handle.state.withLock { $0.pid = 0 }
                return ProcessResult(exitCode: process.terminationStatus, stdoutData: Data(),
                                     stderr: String(decoding: errData, as: UTF8.self))
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            handle.cancel()
        }
    }
}
