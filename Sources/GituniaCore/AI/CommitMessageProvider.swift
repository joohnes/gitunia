import Foundation

public protocol CommitMessageProvider: Sendable {
    var name: String { get }
    var isLocal: Bool { get }
    func generate(prompt: String) async throws -> CommitMessage
}

public enum AIError: Error, LocalizedError, Equatable {
    case providerUnavailable(String)
    case badResponse(raw: String)
    case localOnlyRepo(providerName: String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .providerUnavailable(let why): return why
        case .badResponse(let raw): return "Model did not return valid JSON:\n\(raw)"
        case .localOnlyRepo(let name): return "This repository is marked \"Local AI only\" but \(name) is a cloud provider. Switch to Ollama in Settings."
        case .timeout: return "The model did not respond within 60 seconds."
        }
    }
}

public enum AIProviderFactory {
    public static func make(_ settings: AppSettings) -> any CommitMessageProvider {
        switch settings.aiProvider {
        case .claudeCLI: return ClaudeCLIProvider()
        case .ollama: return OllamaProvider(model: settings.ollamaModel)
        }
    }
}

/// Runs `op` with a 60 s deadline.
func withTimeout<T: Sendable>(seconds: Double = 60, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw AIError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
