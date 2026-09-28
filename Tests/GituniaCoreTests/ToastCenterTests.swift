import XCTest
@testable import GituniaCore

final class ToastCenterTests: XCTestCase {
    @MainActor
    func testPostAndDismiss() {
        let center = ToastCenter(autoDismiss: .seconds(30))
        let toast = Toast.info("hello")
        center.post(toast)
        XCTAssertEqual(center.toasts.map(\.id), [toast.id])
        center.dismiss(toast.id)
        XCTAssertTrue(center.toasts.isEmpty)
    }

    @MainActor
    func testDismissingAlreadyExpiredToastIsNoOp() async throws {
        let center = ToastCenter(autoDismiss: .milliseconds(10))
        let toast = Toast.success("done")
        center.post(toast)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(center.toasts.isEmpty)
        center.dismiss(toast.id) // no-op, must not crash or affect other toasts
        XCTAssertTrue(center.toasts.isEmpty)
    }

    @MainActor
    func testSuccessAndInfoToastsExpire() async throws {
        let center = ToastCenter(autoDismiss: .milliseconds(10))
        center.post(.success("a"))
        center.post(.info("b"))
        XCTAssertEqual(center.toasts.count, 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(center.toasts.isEmpty)
    }

    @MainActor
    func testErrorToastsPersistPastAutoDismissWindow() async throws {
        let center = ToastCenter(autoDismiss: .milliseconds(10))
        let error = Toast.error("failed", stderr: "fatal: boom")
        center.post(error)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(center.toasts.map(\.id), [error.id])
        XCTAssertEqual(center.toasts.first?.stderr, "fatal: boom")
        center.dismiss(error.id)
        XCTAssertTrue(center.toasts.isEmpty)
    }

    @MainActor
    func testQueueCapDropsOldest() {
        let center = ToastCenter(autoDismiss: .seconds(30), maxQueued: 5)
        let posted = (0..<8).map { Toast.info("toast \($0)") }
        for t in posted { center.post(t) }
        XCTAssertEqual(center.toasts.count, 5)
        XCTAssertEqual(center.toasts.map(\.id), posted.suffix(5).map(\.id))
    }

    @MainActor
    func testRemoteResultInitializer() {
        let ok = RemoteResult(kind: .pull, succeeded: true, summary: "Already up to date")
        let okToast = Toast(remote: ok, repo: "gitunia")
        XCTAssertEqual(okToast.style, .success)
        XCTAssertEqual(okToast.detail, "Already up to date")

        let error = GitError(args: ["pull"], exitCode: 1, stderr: "fatal: no upstream")
        let failed = RemoteResult(kind: .pull, succeeded: false, summary: "Pull failed", error: error)
        let failedToast = Toast(remote: failed, repo: "gitunia")
        XCTAssertEqual(failedToast.style, .error)
        XCTAssertEqual(failedToast.stderr, "fatal: no upstream")
    }

    @MainActor
    func testActionToastOutlivesPlainToast() async throws {
        let center = ToastCenter(autoDismiss: .milliseconds(30), actionAutoDismiss: .milliseconds(200))
        center.post(.success("plain"))
        center.post(Toast(style: .success, title: "undoable", action: ToastAction(title: "Undo") {}))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(center.toasts.map(\.title), ["undoable"])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(center.toasts.isEmpty)
    }
}
