import Foundation

public enum ModelOutput {
    private struct Payload: Decodable {
        var title: String
        var body: String?
    }

    /// Extracts the first {...} object from `raw` (tolerating code fences and chatter) and decodes it.
    public static func parseCommitMessage(_ raw: String) throws -> CommitMessage {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            throw AIError.badResponse(raw: raw)
        }
        let json = raw[start...end]
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else {
            throw AIError.badResponse(raw: raw)
        }
        return CommitMessage(title: payload.title.trimmingCharacters(in: .whitespacesAndNewlines),
                             body: (payload.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
