import SwiftUI
import GrablyCore

/// Thumbnail + title + uploader·duration for a successfully probed item.
struct MediaPreviewView: View {
    let info: MediaInfo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title.isEmpty ? "Без названия" : info.title)
                    .font(.headline)
                    .lineLimit(2)
                    .help(info.title)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let uploader = info.uploader, !uploader.isEmpty { parts.append(uploader) }
        if let duration = Formatting.duration(info.duration) { parts.append(duration) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var thumbnail: some View {
        AsyncImage(url: info.thumbnail) { phase in
            switch phase {
            case let .success(image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Color(nsColor: .quaternaryLabelColor)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

#Preview {
    MediaPreviewView(info: MediaInfo(
        id: "x",
        title: "Never Gonna Give You Up",
        uploader: "Rick Astley",
        duration: 213
    ))
    .padding()
    .frame(width: 460)
}
