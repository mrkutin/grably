import Foundation
import Observation
import GrablyCore

/// State of the top URL/probe panel — the single state machine from the UI spec.
enum ProbeState: Equatable {
    case idle
    case invalidURL
    case probing
    case ready(MediaInfo)
    case error(ProbeErrorInfo)

    static func == (lhs: ProbeState, rhs: ProbeState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.invalidURL, .invalidURL), (.probing, .probing):
            return true
        case let (.ready(a), .ready(b)):
            return a.id == b.id
        case let (.error(a), .error(b)):
            return a == b
        default:
            return false
        }
    }
}

/// A user-facing probe failure: a short title plus an explanatory line.
struct ProbeErrorInfo: Equatable, Hashable {
    var title: String
    var message: String
}

/// One selectable video quality (unique height, muxed to `container`).
struct VideoQualityOption: Identifiable, Hashable {
    let height: Int
    let container: String
    let filesize: Int64?

    var id: Int { height }
    var label: String { "\(height)p · \(container)" }
}

/// One selectable audio quality (codec/container).
struct AudioQualityOption: Identifiable, Hashable {
    let codec: DownloadRequest.AudioCodec
    let filesize: Int64?

    var id: String { codec.rawValue }
    var label: String {
        switch codec {
        case .mp3: return "MP3 · 320 kbps"
        case .m4a: return "M4A · AAC"
        }
    }
}

/// Drives the main download UI: URL entry, probe, format selection and the list
/// of active/finished downloads.
@MainActor
@Observable
final class DownloadViewModel {
    // MARK: - Published state

    var urlText: String = "" {
        didSet { handleURLChange() }
    }
    var probeState: ProbeState = .idle
    var selectedKind: MediaKind = .video
    var selectedVideoHeight: Int?
    var selectedAudioCodec: DownloadRequest.AudioCodec = .mp3

    private(set) var videoOptions: [VideoQualityOption] = []
    private(set) var audioOptions: [AudioQualityOption] = []

    /// Active + finished downloads, newest first.
    private(set) var tasks: [DownloadTask] = []

    /// True once binaries are provisioned and the client/manager are attached.
    private(set) var isReady: Bool = false

    // MARK: - Dependencies (attached after provisioning)

    private let settings: SettingsStore
    private var client: YTDLPClient?
    private var manager: DownloadManager?

    private var probeTask: Task<Void, Never>?
    /// The trimmed URL string of the last *successfully* probed request. Used to
    /// tell an incidental re-trigger (same URL) from a real change to a different
    /// URL, so stale results are only dropped in the latter case.
    private var lastProbedInput: String?
    private static let debounce: Duration = .milliseconds(600)

    init(settings: SettingsStore) {
        self.settings = settings
        self.selectedKind = settings.defaultKind
        self.selectedAudioCodec = settings.defaultAudioCodec
    }

    /// Inject the resolved core services once provisioning finishes.
    func attach(client: YTDLPClient, manager: DownloadManager) {
        self.client = client
        self.manager = manager
        self.isReady = true
        // If a URL was already typed while provisioning, probe it now.
        handleURLChange()
    }

    // MARK: - Probe

    private func handleURLChange() {
        // Cancel any in-flight probe. `YTDLPClient.probe` is wired with a
        // cancellation handler that terminates the child yt-dlp process group, so
        // this really kills the old probe instead of leaving it running in the
        // background (BUG 3).
        probeTask?.cancel()
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            lastProbedInput = nil
            clearProbeResults()
            probeState = .idle
            return
        }
        guard isValidURL(trimmed) else {
            clearProbeResults()
            probeState = .invalidURL
            return
        }
        // Same URL we already resolved: keep the existing result, don't re-probe
        // or flicker the panel. (Guards the "text didn't really change" case.)
        if trimmed == lastProbedInput, case .ready = probeState {
            return
        }
        // A change to a *different* URL invalidates whatever preview/formats are on
        // screen, so drop them immediately — otherwise the previous video's data
        // would linger (and could be re-submitted) while the new probe is pending
        // (BUG 3).
        clearProbeResults()

        guard isReady, client != nil else {
            // Binaries not ready yet; attach() re-triggers once provisioning ends.
            probeState = .idle
            return
        }

        // Neutral state while the debounce window elapses; runProbe flips it to
        // `.probing` when the child process actually starts.
        probeState = .idle
        probeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.runProbe(urlString: trimmed)
        }
    }

    /// Drop the currently displayed probe result (preview/format lists), without
    /// touching `urlText` or scheduling anything.
    private func clearProbeResults() {
        videoOptions = []
        audioOptions = []
        selectedVideoHeight = nil
    }

    /// Explicit Fetch / Retry action (bypasses the debounce).
    func fetchNow() {
        probeTask?.cancel()
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidURL(trimmed), isReady else { return }
        probeTask = Task { [weak self] in
            await self?.runProbe(urlString: trimmed)
        }
    }

    func cancelProbe() {
        probeTask?.cancel()
        probeTask = nil
        if case .probing = probeState { probeState = .idle }
    }

    func clearProbe() {
        probeTask?.cancel()
        lastProbedInput = nil
        urlText = ""
        probeState = .idle
        clearProbeResults()
    }

    private func runProbe(urlString: String) async {
        guard let client, let url = URL(string: urlString) else { return }
        probeState = .probing
        do {
            // Apply the current authentication selection before probing so private
            // (but legally-accessible) content resolves with the user's session.
            await client.setAuth(settings.authConfig)
            let info = try await client.probe(url: url)
            guard !Task.isCancelled else { return }
            buildOptions(from: info)
            lastProbedInput = urlString
            probeState = .ready(info)
        } catch is CancellationError {
            // Superseded by a newer edit; leave state as-is.
        } catch let error as MediaInfo.ProbeError {
            probeState = .error(Self.map(error))
        } catch {
            probeState = .error(ProbeErrorInfo(
                title: "Не удалось получить данные",
                message: sanitizedMessage(error)
            ))
        }
    }

    // MARK: - Format options

    private func buildOptions(from info: MediaInfo) {
        // Size of the best *audio-only* stream — the one yt-dlp merges into the
        // video (`bv*+ba`) and the one that becomes the audio-only download.
        // Using `isAudioOnly` (not `hasAudio`) excludes complete muxed formats,
        // whose filesize is video+audio and would badly over-estimate.
        let bestAudioSize = info.formats
            .filter { $0.isAudioOnly }
            .compactMap(\.bestFilesize)
            .max()

        // Best *m4a* audio-only stream — the `ba[ext=m4a]` half of the video
        // selector and the m4a download. `bestAudioSize` can be an opus stream that
        // does not match the m4a that actually gets merged/downloaded, so prefer
        // the m4a size and fall back to `bestAudioSize` only when no m4a exists.
        let bestM4ASize = info.formats
            .filter { $0.isAudioOnly && $0.ext == "m4a" }
            .compactMap(\.bestFilesize)
            .max() ?? bestAudioSize

        // Video: one option per unique height. The real selector is
        // `bv*[height<=H][ext=mp4]+ba[ext=m4a]`, so the estimate must mirror what
        // yt-dlp actually fetches. Crucially, `bv*[ext=mp4]` picks the *best*
        // matching stream, and yt-dlp lists `formats[]` worst→best — so the chosen
        // mp4 video-only stream at a height is the **last** one in array order, NOT
        // the one with the largest filesize. On YouTube the biggest mp4 at a height
        // is usually an avc1 variant that sorts *before* the smaller av01/vp9 stream
        // yt-dlp actually prefers, so taking the max systematically over-estimated
        // (e.g. it picked f134 avc1 ~10.4 MB instead of the selected f396 av01
        // ~7.3 MB). We therefore keep the *last-seen* sized stream per bucket.
        var mp4VideoOnlyByHeight: [Int: Int64] = [:]   // last mp4 video-only per height (size only)
        var anyVideoOnlyByHeight: [Int: Int64] = [:]   // fallback: any codec, per height (size only)
        var completeByHeight: [Int: Int64] = [:]        // muxed (already carries audio) (size only)
        // Height presence is tracked independently of filesize: some sites (e.g. VK)
        // don't report a filesize, and a missing estimate must NOT drop the quality
        // option itself — otherwise "Видео недоступно" appears for perfectly
        // downloadable streams. Filesize, when present, only feeds the size estimate.
        var videoOnlyHeights: Set<Int> = []
        var completeHeights: Set<Int> = []
        for format in info.formats where format.hasVideo {
            guard let height = format.height else { continue }
            let size = format.bestFilesize
            if format.isVideoOnly {
                videoOnlyHeights.insert(height)
                if let size {
                    // Last-seen wins → mirrors `bv*` picking the best (last) match.
                    anyVideoOnlyByHeight[height] = size
                    if format.ext == "mp4" {
                        mp4VideoOnlyByHeight[height] = size
                    }
                }
            } else {
                completeHeights.insert(height)
                if let size {
                    completeByHeight[height] = max(completeByHeight[height] ?? 0, size)
                }
            }
        }
        let heights = videoOnlyHeights.union(completeHeights)
        videoOptions = heights.sorted(by: >).map { height in
            let filesize: Int64?
            // Prefer the mp4 video-only stream `bv*[ext=mp4]` selects; fall back to
            // any-codec video-only at the same height (the remux path), then pair
            // with the m4a audio. Heights offering only a muxed format use it as-is.
            if let videoSize = mp4VideoOnlyByHeight[height] ?? anyVideoOnlyByHeight[height] {
                filesize = bestM4ASize.map { videoSize + $0 } ?? videoSize
            } else {
                filesize = completeByHeight[height]
            }
            return VideoQualityOption(height: height, container: "mp4", filesize: filesize)
        }

        // Audio estimates.
        //
        // mp3: yt-dlp re-encodes the source stream to MP3 (`--audio-quality 0`,
        // VBR ≈ 245 kbps), so the resulting file has no relation to the *source*
        // stream's size (a small opus/webm stream inflates to a much larger MP3).
        // Estimate from playback duration instead: bytes ≈ duration_s · bitrate/8.
        // Fall back to the source stream size only when duration is unknown.
        let mp3Size = Self.mp3Estimate(durationSeconds: info.duration) ?? bestAudioSize

        audioOptions = [
            AudioQualityOption(codec: .mp3, filesize: mp3Size),
            AudioQualityOption(codec: .m4a, filesize: bestM4ASize)
        ]

        // Default selection: best video ≤ preferred ceiling, else the highest.
        let ceiling = settings.defaultVideoHeight
        let atOrBelow = videoOptions.filter { $0.height <= ceiling }.map(\.height).max()
        selectedVideoHeight = atOrBelow ?? videoOptions.first?.height
        selectedAudioCodec = settings.defaultAudioCodec

        // Honor the default type, but fall back to whatever is available.
        if settings.defaultKind == .video, !videoOptions.isEmpty {
            selectedKind = .video
        } else if !audioOptions.isEmpty, videoOptions.isEmpty {
            selectedKind = .audio
        } else {
            selectedKind = settings.defaultKind
        }
    }

    /// Approximate encoded size (bytes) of an MP3 produced at yt-dlp's
    /// `--audio-quality 0` (VBR ≈ 245 kbps) for a clip of the given duration.
    /// Returns `nil` when the duration is unknown so callers can fall back.
    private static func mp3Estimate(durationSeconds: Double?) -> Int64? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        let bitsPerSecond = 245_000.0
        return Int64(durationSeconds * bitsPerSecond / 8)
    }

    var hasVideoFormats: Bool { !videoOptions.isEmpty }
    var hasAudioFormats: Bool { !audioOptions.isEmpty }

    /// The estimated size for the current selection, if known.
    var selectedFilesize: Int64? {
        switch selectedKind {
        case .video:
            return videoOptions.first { $0.height == selectedVideoHeight }?.filesize
        case .audio:
            return audioOptions.first { $0.codec == selectedAudioCodec }?.filesize
        }
    }

    var canDownload: Bool {
        guard isReady, manager != nil else { return false }
        switch selectedKind {
        case .video: return selectedVideoHeight != nil
        case .audio: return true
        }
    }

    // MARK: - Download

    func startDownload() {
        guard let manager, canDownload,
              case let .ready(info) = probeState,
              let url = info.webpageURL ?? URL(string: urlText) else { return }

        let kind: DownloadRequest.Kind
        switch selectedKind {
        case .video:
            guard let height = selectedVideoHeight else { return }
            kind = .video(height: height, container: "mp4")
        case .audio:
            kind = .audio(codec: selectedAudioCodec)
        }

        do {
            let request = try DownloadRequest.validated(
                url: url,
                kind: kind,
                destinationDirectory: settings.downloadDirectory
            )
            let task = DownloadTask(
                id: request.id,
                request: request,
                state: .queued,
                mediaInfo: info
            )
            tasks.insert(task, at: 0)
            // Push the current auth to the client before the queue starts the job,
            // so the download uses the same session the probe did. The serial queue
            // (maxConcurrent == 1) guarantees this ordering holds.
            let auth = settings.authConfig
            Task {
                await client?.setAuth(auth)
                await manager.enqueue(request)
            }
        } catch {
            probeState = .error(ProbeErrorInfo(
                title: "Некорректная ссылка",
                message: sanitizedMessage(error)
            ))
        }
    }

    func cancel(_ task: DownloadTask) {
        guard let manager else { return }
        Task { await manager.cancel(task.id) }
    }

    func retry(_ task: DownloadTask) {
        guard let manager else { return }
        // Reset the row and re-enqueue the same request.
        update(id: task.id) { $0.state = .queued; $0.progress = .zero }
        Task { await manager.enqueue(task.request) }
    }

    func remove(_ task: DownloadTask) {
        tasks.removeAll { $0.id == task.id }
    }

    func clearFinished() {
        tasks.removeAll { task in
            switch task.state {
            case .completed, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    // MARK: - Event routing (called by AppEnvironment's listener)

    func apply(_ event: DownloadManagerEvent) {
        switch event {
        case let .stateChanged(id, state):
            update(id: id) { $0.state = state }
        case let .progress(id, progress):
            update(id: id) { $0.progress = progress }
        }
    }

    private func update(id: UUID, _ mutate: (inout DownloadTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
    }

    // MARK: - Validation & mapping

    private func isValidURL(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return (try? DownloadRequest.validate(url: url)) != nil
    }

    private func sanitizedMessage(_ error: Error) -> String {
        String(describing: error)
    }

    private static func map(_ error: MediaInfo.ProbeError) -> ProbeErrorInfo {
        switch error {
        case .playlist:
            return ProbeErrorInfo(
                title: "Это плейлист",
                message: "Вставьте ссылку на конкретное видео, а не на плейлист или канал."
            )
        case .noFormats:
            return ProbeErrorInfo(
                title: "Нет форматов",
                message: "Для этой ссылки не нашлось доступных форматов."
            )
        case let .failed(raw):
            return mapFailed(raw)
        }
    }

    private static func mapFailed(_ raw: String) -> ProbeErrorInfo {
        let lowered = raw.lowercased()
        if lowered.contains("приватн") || lowered.contains("private") || lowered.contains("removed") {
            return ProbeErrorInfo(
                title: "Видео недоступно",
                message: "Ролик приватный или удалён. Проверьте ссылку."
            )
        }
        if lowered.contains("регион") || lowered.contains("geo")
            || lowered.contains("your country") {
            return ProbeErrorInfo(
                title: "Недоступно в вашем регионе",
                message: "Владелец ограничил доступ по стране."
            )
        }
        if lowered.contains("возраст") || lowered.contains("age") {
            return ProbeErrorInfo(
                title: "Требуется подтверждение возраста",
                message: "Это видео с возрастным ограничением."
            )
        }
        if lowered.contains("сет") || lowered.contains("network")
            || lowered.contains("timed out") || lowered.contains("unable to download") {
            return ProbeErrorInfo(
                title: "Нет соединения",
                message: "Проверьте интернет и повторите."
            )
        }
        if lowered.contains("unsupported") || lowered.contains("не поддерж") {
            return ProbeErrorInfo(
                title: "Сайт не поддерживается",
                message: "Не удалось распознать ссылку."
            )
        }
        return ProbeErrorInfo(
            title: "Не удалось получить данные",
            message: raw.isEmpty ? "yt-dlp завершился с ошибкой." : raw
        )
    }
}
