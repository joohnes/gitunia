import Foundation

extension RepositoryStore {
    /// The full hash of the commit `ref` names (full/short hash, branch, tag, `HEAD~2`…), or nil.
    public func resolveCommit(_ ref: String) async -> String? {
        let ref = ref.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty, !ref.hasPrefix("-") else { return nil }
        let out = try? await git.run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: url)
        let hash = out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return hash.isEmpty ? nil : hash
    }
}
