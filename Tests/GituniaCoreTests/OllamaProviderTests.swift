import XCTest
@testable import GituniaCore

final class OllamaProviderTests: XCTestCase {
    func testCancelledRequestThrowsCancellationError() async throws {
        var provider = OllamaProvider(model: "x")
        provider.baseURL = URL(string: "http://10.255.255.1:11434")!

        let task = Task { try await provider.generate(prompt: "hi") }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        let start = Date()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)

        switch result {
        case .success:
            XCTFail("expected cancellation error")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }
}
