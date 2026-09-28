import XCTest
@testable import GituniaCore

final class ProcessRunnerTests: XCTestCase {
    func testCancellationTerminatesChildProcess() async throws {
        let task = Task {
            try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"])
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        task.cancel()
        let result = await task.result
        let elapsed = Date().timeIntervalSince(start)

        switch result {
        case .success:
            XCTFail("expected cancellation to fail the task")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(elapsed, 5, "child process was not terminated promptly on cancellation")
    }

    func testCancellationBeforeRunDoesNotLaunchProcess() async throws {
        let task = Task {
            try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"])
        }
        let start = Date()
        task.cancel()
        let result = await task.result
        let elapsed = Date().timeIntervalSince(start)

        switch result {
        case .success:
            XCTFail("expected cancellation to fail the task")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(elapsed, 5, "cancellation racing process launch did not fail fast")
    }

    /// A backgrounded grandchild inherits the pipe fds and outlives `terminate()` on the direct
    /// child, which used to block `readDataToEndOfFile` forever (docs/next-round-plan.md A1).
    /// ponytail: the grandchild itself isn't killed (only the direct child's pid is — no process
    /// group), so it still runs out its 30s orphaned; this only asserts the reader stops blocking.
    func testCancellationReturnsPromptlyWithGrandchildHoldingPipeOpen() async throws {
        let marker = "gitunia-test-\(UUID().uuidString)"
        let task = Task {
            try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "sleep 30 & sleep 30 # \(marker)"])
        }
        try await Task.sleep(for: .milliseconds(300))
        let start = Date()
        task.cancel()
        let result = await task.result
        let elapsed = Date().timeIntervalSince(start)

        switch result {
        case .success:
            XCTFail("expected cancellation to fail the task")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(elapsed, 4, "reader stayed blocked on the grandchild's pipe past the 2s grace ceiling")
    }
}
