import Foundation

/// Talks to a local Ollama server. Local provider (isLocal = true).
public struct OllamaProvider: CommitMessageProvider {
    public let name = "Ollama"
    public let isLocal = true
    public let model: String
    public var baseURL = URL(string: "http://localhost:11434")!

    public init(model: String) { self.model = model }

    public func generate(prompt: String) async throws -> CommitMessage {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "prompt": prompt, "stream": false, "format": "json",
        ])
        req.timeoutInterval = 60

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIError.providerUnavailable("Ollama is not running at \(baseURL.absoluteString). Install from https://ollama.com and run `ollama pull \(model)`.")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            throw AIError.providerUnavailable("Ollama returned HTTP \(http.statusCode): \(body)")
        }
        struct Envelope: Decodable { var response: String?; var error: String? }
        let env = try? JSONDecoder().decode(Envelope.self, from: data)
        if let err = env?.error { throw AIError.providerUnavailable("Ollama: \(err)") }
        return try ModelOutput.parseCommitMessage(env?.response ?? String(decoding: data, as: UTF8.self))
    }
}
