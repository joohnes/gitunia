import SwiftUI

/// The `cpu` mark before an author that `RepositoryStore.agentProfile` says is an agent — one view
/// so History, file history and Compare rows stay identical.
struct AgentGlyph: View {
    var body: some View {
        Image(systemName: "cpu").help("Agent commit")
    }
}
