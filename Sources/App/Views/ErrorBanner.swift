import SwiftUI

/// Inline probe-error banner shown in place of the format panel.
struct ErrorBanner: View {
    let info: ProbeErrorInfo
    var onClear: () -> Void
    var onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .font(.headline)
                Text(info.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Очистить", action: onClear)
                    Button("Повторить", action: onRetry)
                        .keyboardShortcut("r", modifiers: .command)
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.yellow.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ошибка: \(info.title). \(info.message)")
    }
}

#Preview {
    ErrorBanner(
        info: ProbeErrorInfo(
            title: "Видео недоступно",
            message: "Ролик приватный или удалён. Проверьте ссылку."
        ),
        onClear: {}, onRetry: {}
    )
    .padding()
    .frame(width: 460)
}
