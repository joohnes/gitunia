import SwiftUI
import GituniaCore

/// Bottom-trailing toast stack, newest at the bottom. Mounted once on the WindowGroup root in
/// GituniaApp (not inside ContentView — that file belongs to a later task).
struct ToastOverlay: View {
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(toasts.toasts) { toast in
                ToastRow(toast: toast) { toasts.dismiss(toast.id) }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.95))
                    ))
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 56) // clears the commit box / window bottom controls
        .frame(maxWidth: 360, alignment: .trailing)
        .animation(.spring(duration: 0.3), value: toasts.toasts.map(\.id))
        // Hit-transparent where there's no content: the VStack sizes to its children, so
        // clicks outside the toasts fall through to the window underneath.
        .allowsHitTesting(!toasts.toasts.isEmpty)
    }
}

private struct ToastRow: View {
    let toast: Toast
    let onDismiss: () -> Void
    @State private var showDetails = false

    /// Error toasts only — they stay until dismissed, so the popover can't vanish under the user.
    private var hasDetails: Bool { toast.style == .error }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.body.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.subheadline.weight(.semibold))
                if let detail = toast.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let action = toast.action {
                    Button(action.title) {
                        action.perform()
                        onDismiss()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.brand)
                }
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                if hasDetails {
                    Button("Details…") { showDetails = true }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(iconColor.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .contentShape(Rectangle())
        .onTapGesture { if hasDetails { showDetails = true } }
        .help(hasDetails ? "Click for details" : "")
        .popover(isPresented: $showDetails, arrowEdge: .leading) {
            ToastDetails(toast: toast)
        }
    }

    private var iconName: String {
        switch toast.style {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch toast.style {
        case .success: Theme.brand
        case .info: .secondary
        case .error: Theme.status(.deleted)
        }
    }
}

/// What an error toast's one-line summary leaves out: the command that ran and git's full output,
/// selectable and copyable.
struct ToastDetails: View {
    let toast: Toast

    private var copyText: String {
        [toast.command.map { "$ \($0)" }, toast.stderr ?? toast.detail].compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(toast.title).font(.headline)
            if let detail = toast.detail {
                Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let command = toast.command {
                Text("$ \(command)")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let stderr = toast.stderr?.trimmingCharacters(in: .whitespacesAndNewlines), !stderr.isEmpty {
                ScrollView {
                    Text(stderr)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 260)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText, forType: .string)
                }
            }
        }
        .padding(14)
        .frame(width: 460)
    }
}
