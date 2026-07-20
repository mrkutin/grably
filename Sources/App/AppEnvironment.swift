import Foundation
import Observation
import GrablyCore

/// Provisioning lifecycle of the bundled helper binaries.
enum ProvisionState: Equatable {
    case preparing
    case ready
    case failed(String)
}

/// Composition root: owns the long-lived core services, provisions the bundled
/// binaries on launch, wires the ``DownloadManager`` event stream into the view
/// model, and exposes provisioning state to the UI.
@MainActor
@Observable
final class AppEnvironment {
    let settingsStore: SettingsStore
    let downloadViewModel: DownloadViewModel
    let engineUpdater: EngineUpdaterModel

    private(set) var provisionState: ProvisionState = .preparing

    private var manager: DownloadManager?
    private var eventsTask: Task<Void, Never>?

    init() {
        let settingsStore = SettingsStore()
        self.settingsStore = settingsStore
        let downloadViewModel = DownloadViewModel(settings: settingsStore)
        self.downloadViewModel = downloadViewModel
        self.engineUpdater = EngineUpdaterModel()
        Task { await bootstrap() }
    }

    // MARK: - Provisioning

    private func bootstrap() async {
        do {
            let sourceDirectory = Self.bundledBinDirectory()
            let supportDirectory = try Self.supportBinDirectory()

            let provisioner = BinaryProvisioner(
                sourceDirectory: sourceDirectory,
                supportDirectory: supportDirectory
            )
            let binaries = try await provisioner.resolve()

            let runner = ProcessRunner()
            let client = YTDLPClient(binaries: binaries, runner: runner)
            let manager = DownloadManager(
                client: client,
                maxConcurrent: 1
            )
            self.manager = manager

            downloadViewModel.attach(client: client, manager: manager)
            startEventsListener(manager)

            // Wire the self-updater to the same yt-dlp binary and process runner.
            let updater = YTDLPUpdater(ytDlpURL: binaries.ytDlp, runner: runner)
            engineUpdater.attach(updater: updater)

            provisionState = .ready
        } catch {
            provisionState = .failed(Self.describe(error))
        }
    }

    private func startEventsListener(_ manager: DownloadManager) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            let stream = await manager.events()
            for await event in stream {
                guard let self else { return }
                await MainActor.run {
                    self.downloadViewModel.apply(event)
                }
            }
        }
    }

    // MARK: - Paths

    /// The bundled originals live in `Contents/Resources/bin` (copied there by the
    /// folder-reference resource in project.yml).
    private static func bundledBinDirectory() -> URL {
        if let resourceURL = Bundle.main.resourceURL {
            return resourceURL.appendingPathComponent("bin", isDirectory: true)
        }
        // Extremely defensive fallback; should never hit in a real bundle.
        return Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin", isDirectory: true)
    }

    /// Writable copy target: `~/Library/Application Support/grably/bin`.
    private static func supportBinDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("grably", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let BinaryError.sourceMissing(name):
            return "Не найден компонент «\(name)». Переустановите приложение."
        case let BinaryError.untrustedBinary(name):
            return "Компонент «\(name)» не прошёл проверку и не был запущен."
        case let BinaryError.copyFailed(name):
            return "Не удалось подготовить «\(name)» к запуску."
        default:
            return String(describing: error)
        }
    }
}
