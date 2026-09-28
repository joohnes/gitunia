import Foundation

/// Cancel-and-reschedule: only the last `schedule`d work runs, `delay` after it was scheduled.
@MainActor
final class Debouncer {
    private var task: Task<Void, Never>?
    private var work: (@MainActor () -> Void)?

    nonisolated init() {}

    func schedule(_ delay: Duration, _ work: @escaping @MainActor () -> Void) {
        task?.cancel()
        self.work = work
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Runs the pending work now, if any.
    func flush() {
        let pending = work
        cancel()
        pending?()
    }

    func cancel() {
        task?.cancel()
        task = nil
        work = nil
    }
}

enum FileBackup {
    /// Copies an unreadable file to `<name>.corrupt-<timestamp>` next to it before it gets reset.
    /// Returns the backup's URL (the copy itself is best-effort).
    @discardableResult
    static func preserveCorrupt(at url: URL) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".corrupt-\(stamp)")
        try? FileManager.default.copyItem(at: url, to: backup)
        return backup
    }
}
