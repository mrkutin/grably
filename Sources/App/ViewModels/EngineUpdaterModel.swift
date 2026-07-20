import Foundation
import Observation
import GrablyCore

/// UI state of the "Движок yt-dlp" section in Settings (spec §2.2).
enum EngineUpdateUIState: Equatable {
    /// Version not yet known (before the first `currentVersion` load).
    case unknown
    /// Idle: installed `current`; `latest` is set only when an update is available.
    case idle(current: String, latest: String?)
    /// A version check is in flight.
    case checking
    /// A download/swap is in flight, targeting the carried version.
    case updating(String)
    /// Just updated to `version` (auto-reverts to `.idle` after a few seconds).
    case done(String)
    /// The last check/update failed; carries a user-facing message.
    case error(String)
}

/// Drives the yt-dlp version display and the "Проверить/Обновить" button.
///
/// Owns no long-lived work on the main actor: every call hops onto the
/// ``YTDLPUpdater`` actor via a `Task` and only mutates observable state back on the
/// main actor.
@MainActor
@Observable
final class EngineUpdaterModel {
    private(set) var state: EngineUpdateUIState = .unknown

    private var updater: YTDLPUpdater?
    private var activeTask: Task<Void, Never>?
    private var revertTask: Task<Void, Never>?

    /// Seconds the `.done` confirmation stays visible before reverting to `.idle`.
    private static let doneVisibleSeconds: Duration = .seconds(3)

    /// Inject the core updater once the binaries are provisioned, then load the
    /// currently installed version.
    func attach(updater: YTDLPUpdater) {
        self.updater = updater
        loadCurrentVersion()
    }

    /// Whether the primary button should be disabled (work in flight).
    var isBusy: Bool {
        switch state {
        case .checking, .updating: return true
        default: return false
        }
    }

    /// Load and display the installed version without contacting the network.
    ///
    /// A no-op while a check/update is in flight: it must never cancel an active
    /// `.updating` (that would abort the download mid-swap) or `.checking`.
    func loadCurrentVersion() {
        guard let updater else { return }
        if isBusy { return }
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            do {
                let current = try await updater.currentVersion()
                guard let self, !Task.isCancelled else { return }
                if case .done = self.state { return } // don't clobber a confirmation
                self.state = .idle(current: current, latest: nil)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .error(Self.message(for: error))
            }
        }
    }

    /// Check for a newer release and, if one exists, download and install it.
    func checkAndUpdate() {
        guard let updater else { return }
        revertTask?.cancel()
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await self?.runCheckAndUpdate(updater)
        }
    }

    private func runCheckAndUpdate(_ updater: YTDLPUpdater) async {
        state = .checking
        do {
            let status = try await updater.checkForUpdate()
            guard !Task.isCancelled else { return }
            switch status {
            case let .upToDate(current):
                state = .idle(current: current, latest: nil)
            case let .updateAvailable(current, latest):
                _ = current // shown as "доступно" while updating
                state = .updating(latest)
                // The version reported by `update()` is authoritative (it is what
                // the freshly installed binary reports for the single resolved tag).
                let newVersion = try await updater.update()
                guard !Task.isCancelled else { return }
                state = .done(newVersion)
                scheduleRevert(to: newVersion)
            }
        } catch {
            guard !Task.isCancelled else { return }
            state = .error(Self.message(for: error))
        }
    }

    private func scheduleRevert(to version: String) {
        revertTask?.cancel()
        revertTask = Task { [weak self] in
            try? await Task.sleep(for: Self.doneVisibleSeconds)
            guard let self, !Task.isCancelled else { return }
            self.state = .idle(current: version, latest: nil)
        }
    }

    private static func message(for error: Error) -> String {
        if let updaterError = error as? UpdaterError {
            return updaterError.errorDescription ?? "Не удалось обновить yt-dlp."
        }
        return "Не удалось обновить yt-dlp."
    }
}
