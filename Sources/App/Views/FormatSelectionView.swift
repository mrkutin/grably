import SwiftUI
import GrablyCore

/// Media-type segment + quality picker + primary Download CTA.
struct FormatSelectionView: View {
    @Bindable var viewModel: DownloadViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            typeSegment
            qualityRow
            downloadRow
        }
    }

    // MARK: - Type segment

    private var typeSegment: some View {
        Picker("Тип загрузки", selection: $viewModel.selectedKind) {
            Label("Видео", systemImage: "video").tag(MediaKind.video)
            Label("Аудио", systemImage: "music.note").tag(MediaKind.audio)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 280, alignment: .leading)
        .disabled(!viewModel.hasVideoFormats && !viewModel.hasAudioFormats)
        .accessibilityLabel("Тип загрузки")
    }

    // MARK: - Quality

    @ViewBuilder
    private var qualityRow: some View {
        HStack(spacing: 12) {
            switch viewModel.selectedKind {
            case .video:
                if viewModel.hasVideoFormats {
                    Picker("Качество", selection: videoBinding) {
                        ForEach(viewModel.videoOptions) { option in
                            Text(option.label).tag(option.height)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                } else {
                    Text("Видео недоступно для этой ссылки")
                        .foregroundStyle(.secondary)
                }
            case .audio:
                Picker("Качество", selection: $viewModel.selectedAudioCodec) {
                    ForEach(viewModel.audioOptions) { option in
                        Text(option.label).tag(option.codec)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
            }

            if let size = Formatting.approxFileSize(viewModel.selectedFilesize) {
                Text("Размер \(size)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Качество")
    }

    private var videoBinding: Binding<Int> {
        Binding(
            get: { viewModel.selectedVideoHeight ?? viewModel.videoOptions.first?.height ?? 0 },
            set: { viewModel.selectedVideoHeight = $0 }
        )
    }

    // MARK: - Download

    private var downloadRow: some View {
        HStack {
            Spacer()
            Button(action: viewModel.startDownload) {
                Label("Download", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(BrandColor.navy)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!viewModel.canDownload)
            .accessibilityLabel("Скачать")
            .accessibilityHint("Начать загрузку выбранного формата")
        }
    }
}
