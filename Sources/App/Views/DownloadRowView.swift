import SwiftUI
import AppKit
import GrablyCore

struct DownloadRowView: View {
    var task: DownloadTask
    var onCancel: () -> Void
    var onRetry: () -> Void
    var onRemove: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: task.typeSymbol)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                titleRow
                Text(task.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                progressArea
                bottomRow
            }

            trailingAction
                .frame(width: 28, height: 28)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
        )
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.displayTitle), \(task.displaySubtitle)")
        .accessibilityValue(accessibilityValue)
    }

    // MARK: - Rows

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(task.displayTitle)
                .font(.body)
                .lineLimit(1)
                .help(task.displayTitle)
            statusIcon
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.state {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    /// True while a running task has not yet received a single byte — yt-dlp is
    /// still extracting/preparing and emits no download progress. A determinate
    /// bar would sit dead at 0 during this window, so we show an indeterminate one.
    private var isPreparing: Bool {
        if case .running = task.state {
            return task.progress.downloadedBytes == 0
        }
        return false
    }

    @ViewBuilder
    private var progressArea: some View {
        switch task.state {
        case .running where isPreparing:
            // Extraction/preparation: no bytes yet → indeterminate spinner-bar
            // instead of a determinate bar stuck at 0.
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.accentColor)
        case .queued, .running, .paused:
            ProgressView(value: task.progress.fraction)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .animation(reduceMotion ? nil : .linear(duration: 0.3), value: task.progress.fraction)
        case .postProcessing:
            // Merge/remux is indeterminate — yt-dlp reports no fraction here.
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.accentColor)
        case .completed, .failed, .cancelled:
            EmptyView()
        }
    }

    @ViewBuilder
    private var bottomRow: some View {
        switch task.state {
        case .queued:
            caption("В очереди")
        case .running where isPreparing:
            // No bytes yet: show a phase label rather than a misleading "0%".
            caption("Подготовка…")
        case .running, .paused:
            HStack(spacing: 8) {
                Text(Formatting.percent(task.progress.fraction))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                if let detail = downloadDetail {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        case let .postProcessing(label):
            caption(label)
        case let .completed(url):
            HStack(spacing: 10) {
                Text("Готово").font(.caption).foregroundStyle(.secondary)
                Button("Показать в Finder") { reveal(url) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case .cancelled:
            caption("Отменено")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private var downloadDetail: String? {
        var parts: [String] = []
        if let speed = Formatting.speed(task.progress.speed) { parts.append(speed) }
        if let eta = Formatting.eta(task.progress.eta) { parts.append(eta) }
        return parts.isEmpty ? nil : "· " + parts.joined(separator: " · ")
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailingAction: some View {
        switch task.state {
        case .queued, .running:
            Button(action: onCancel) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Отменить загрузку")
            .accessibilityLabel("Отменить загрузку")
        case .postProcessing, .paused:
            Color.clear
        case .completed:
            Color.clear
        case .failed, .cancelled:
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Повторить загрузку")
            .accessibilityLabel("Повторить загрузку")
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if case let .completed(url) = task.state {
            Button("Показать в Finder") { reveal(url) }
        }
        Button("Скопировать ссылку") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.request.url.absoluteString, forType: .string)
        }
        Button("Скачать снова", action: onRetry)
        Divider()
        Button("Удалить из списка", role: .destructive, action: onRemove)
    }

    // MARK: - Helpers

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var accessibilityValue: String {
        switch task.state {
        case .queued: return "В очереди"
        case .running where isPreparing: return "Подготовка"
        case .running, .paused:
            var value = "Загрузка \(Formatting.percent(task.progress.fraction))"
            if let speed = Formatting.speed(task.progress.speed) { value += ", \(speed)" }
            if let eta = Formatting.eta(task.progress.eta) { value += ", \(eta)" }
            return value
        case let .postProcessing(label): return label
        case .completed: return "Готово"
        case let .failed(message): return "Ошибка: \(message)"
        case .cancelled: return "Отменено"
        }
    }
}

#Preview {
    DownloadRowView(
        task: DownloadTask(
            request: DownloadRequest(
                url: URL(string: "https://example.com/video")!,
                kind: .video(height: 1080, container: "mp4"),
                destinationDirectory: FileManager.default.temporaryDirectory
            ),
            state: .running,
            progress: DownloadProgress(status: "downloading", downloadedBytes: 620,
                                       totalBytes: 1000, speed: 8_400_000, eta: 6),
            mediaInfo: MediaInfo(id: "x", title: "Never Gonna Give You Up")
        ),
        onCancel: {}, onRetry: {}, onRemove: {}
    )
    .padding()
    .frame(width: 460)
}
