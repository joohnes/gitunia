import XCTest
@testable import GituniaCore

final class ToastCenterTests: XCTestCase {
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
