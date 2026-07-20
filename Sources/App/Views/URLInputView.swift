import SwiftUI
import UniformTypeIdentifiers

struct URLInputView: View {
    @Binding var urlText: String
    var probeState: ProbeState
    var onFetch: () -> Void
    var onCancelProbe: () -> Void

    @State private var isDropTargeted = false
    @FocusState private var fieldFocused: Bool

    private var isProbing: Bool {
        if case .probing = probeState { return true }
        return false
    }

    private var isInvalid: Bool {
        if case .invalidURL = probeState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                field
                fetchButton
            }
        }
        .onDrop(of: [.url, .plainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            TextField("Вставьте ссылку на видео…", text: $urlText)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                // Never disable the field: it must stay editable so the user can
                // select/replace/paste a new URL at any moment, even while a probe
                // of the previous URL is still running (BUG 3).
                .onSubmit(onFetch)
                .accessibilityLabel("Ссылка на видео")
                .accessibilityHint("Вставьте ссылку и нажмите Fetch")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: isDropTargeted ? 2 : 1)
        )
    }

    private var borderColor: Color {
        if isInvalid { return .red }
        if isDropTargeted { return .accentColor }
        return Color(nsColor: .separatorColor)
    }

    @ViewBuilder
    private var fetchButton: some View {
        if isProbing {
            Button(action: onCancelProbe) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Отмена")
                }
            }
            .accessibilityLabel("Отменить анализ")
        } else {
            Button(action: onFetch) {
                Text("Fetch").foregroundStyle(BrandColor.navy)
            }
            .buttonStyle(.borderedProminent)
            .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isInvalid)
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityLabel("Анализировать ссылку")
        }
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in urlText = url.absoluteString }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                guard let text = text as? String else { return }
                Task { @MainActor in
                    urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return true
        }
        return false
    }
}

#Preview {
    VStack(spacing: 16) {
        URLInputView(urlText: .constant(""), probeState: .idle, onFetch: {}, onCancelProbe: {})
        URLInputView(urlText: .constant("nope"), probeState: .invalidURL, onFetch: {}, onCancelProbe: {})
        URLInputView(urlText: .constant("https://x"), probeState: .probing, onFetch: {}, onCancelProbe: {})
    }
    .padding()
    .frame(width: 460)
}
