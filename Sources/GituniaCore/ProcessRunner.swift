import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdoutData: Data
    public let stderr: String
    public var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
}

/// Box so a `Process` (a reference type Foundation does not mark `Sendable`) can cross the
/// cancellation-handler / detached-task boundary. `cancel()` and `runUnlessCancelled()` are
/// mutually exclusive under a lock so a cancellation racing `process.run()` can never both miss
/// terminating a launched process and let a not-yet-launched process start unterminated (TOCTOU).
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var pipes: (out: Pipe, err: Pipe, in: Pipe?)?

    /// Called once the pipes exist so `cancel()` can force-close them past the grace period —
    /// `git` itself may exit promptly on SIGTERM, but `ssh`/credential helpers/`gh` inherit the
    /// same stdout/stderr and can keep the write end open, blocking the drain reads forever.
    func setPipes(out: Pipe, err: Pipe, in inPipe: Pipe?) {
        lock.lock(); defer { lock.unlock() }
        pipes = (out, err, inPipe)
    }

    /// Called from the cancellation handler. Either prevents a future run() or terminates a running
    /// process, then gives it a fixed 2s grace period before force-closing the pipes (unblocking any
    /// drain/writer thread still stuck reading/writing) and SIGKILLing the child if still alive.
    /// Ceiling: 2s — a process tree that outlives that gets its pipes yanked out from under it.
    func cancel() {
        lock.lock()
        cancelled = true
        let running = process.isRunning
        if running { process.terminate() }
        lock.unlock()
        guard running else { return }
        Thread {
            Thread.sleep(forTimeInterval: 2)
            self.lock.lock()
            let stillRunning = self.process.isRunning
            let pipes = self.pipes
            self.lock.unlock()
            if stillRunning { kill(self.process.processIdentifier, SIGKILL) }
            try? pipes?.out.fileHandleForReading.close()
            try? pipes?.err.fileHandleForReading.close()
            try? pipes?.in?.fileHandleForWriting.close()
        }.start()
    }

    /// Starts the process unless cancel() already happened. Throws CancellationError in that case.
    func runUnlessCancelled() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
    }
}

/// Runs an external process, draining stdout and stderr concurrently so large outputs never deadlock.
/// Cancelling the calling `Task` terminates the child process (SIGTERM) instead of leaking it.
public enum ProcessRunner {
    public static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:],
        stdin: String? = nil
    ) async throws -> ProcessResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .userInitiated) {
                try runSync(box: box, executable: executable, arguments: arguments, currentDirectory: currentDirectory,
                            environment: environment, stdin: stdin)
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            box.cancel()
        }
    }

    private static func runSync(
        box: ProcessBox, executable: String, arguments: [String], currentDirectory: URL?,
        environment: [String: String], stdin: String?
    ) throws -> ProcessResult {
        let process = box.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        if let inPipe { process.standardInput = inPipe }
        box.setPipes(out: outPipe, err: errPipe, in: inPipe)

        try box.runUnlessCancelled()

        let group = DispatchGroup()

        // Dedicated threads, not `DispatchQueue.global()`: if the global pool is exhausted (seen in
        // the offscreen render tests, where AppKit parks ~70 workers in blocking animations) the
        // stderr drain never starts and `group.wait()` below hangs forever.
        if let inPipe, let stdin {
            group.enter()
            Thread {
                inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                try? inPipe.fileHandleForWriting.close()
                group.leave()
            }.start()
        }

        // `readToEnd()`, not the legacy `readDataToEndOfFile()`: on cancellation `ProcessBox.cancel()`
        // closes these read ends past its grace period to unblock a drain still stuck behind a
        // grandchild (ssh, a credential helper, `gh`) holding the write end open, and the legacy API
        // raises an uncatchable ObjC exception on that rather than throwing.
        nonisolated(unsafe) var errData = Data()
        group.enter()
        Thread {
            errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            group.leave()
        }.start()
        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        group.wait()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdoutData: outData,
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
