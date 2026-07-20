import SwiftUI

/// Thin global banner under the toolbar for provisioning failures / warnings.
struct HeaderBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.15))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Предупреждение: \(message)")
    }
}

/// A slim "preparing components" strip shown while binaries provision.
struct PreparingBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Подготовка компонентов…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10))
    }
}

#Preview {
    VStack(spacing: 0) {
        HeaderBanner(message: "yt-dlp не найден. Переустановите приложение.")
        PreparingBanner()
    }
    .frame(width: 460)
}
