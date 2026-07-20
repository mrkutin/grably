import Foundation

/// Lifecycle state of a download.
public enum DownloadState: Hashable, Sendable {
    case queued
    case running
    /// Reserved: there is no pause API yet. Kept in the public enum so a future
    /// pause/resume feature does not become a source-breaking change for clients
    /// that switch over `DownloadState` exhaustively.
    case paused
    /// A post-processing step is running (mux / audio extract / remux); the
    /// associated value is a user-facing phase label.
    case postProcessing(String)
    case completed(URL)
    case failed(String)
    case cancelled

    /// Whether this is a final state a task will not leave on its own.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .queued, .running, .paused, .postProcessing: return false
        }
    }
}

/// An in-flight or finished download tracked by the download manager.
public struct DownloadTask: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let request: DownloadRequest
    public var state: DownloadState
    public var progress: DownloadProgress
    public var mediaInfo: MediaInfo?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        request: DownloadRequest,
        state: DownloadState = .queued,
        progress: DownloadProgress = .zero,
        mediaInfo: MediaInfo? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.request = request
        self.state = state
        self.progress = progress
        self.mediaInfo = mediaInfo
        self.createdAt = createdAt
    }
}
