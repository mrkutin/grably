import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GrablyCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var settings = environment.settingsStore

        TabView {
            generalTab(settings)
                .tabItem { Label("Общие", systemImage: "gearshape") }

            engineTab
                .tabItem { Label("Движок", systemImage: "arrow.triangle.2.circlepath") }

            aboutTab
                .tabItem { Label("О программе", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 320)
    }

    // MARK: - About

    private var aboutTab: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    if let icon = NSImage(named: "AppIcon") {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Grably")
                            .font(.title2.weight(.semibold))
                        Text("grab any video")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("Версия") {
                LabeledContent("Версия") {
                    Text(Self.appVersion).monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Сборка") {
                    Text(Self.buildNumber).monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Конфигурация") {
                    Text(Self.buildConfiguration).monospaced().foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Авторские права") {
                    Text("© 2026").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private static var buildConfiguration: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }

    // MARK: - General

    private func generalTab(_ store: SettingsStore) -> some View {
        @Bindable var settings = store
        return Form {
            Section("Папка загрузок") {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(settings.downloadDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Выбрать…") { chooseFolder(settings) }
                }
            }

            Section("Формат по умолчанию") {
                Picker("Тип", selection: $settings.defaultKind) {
                    Text("Видео").tag(MediaKind.video)
                    Text("Аудио").tag(MediaKind.audio)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()

                Picker("Качество видео", selection: $settings.defaultVideoHeight) {
                    ForEach([2160, 1440, 1080, 720, 480, 360], id: \.self) { h in
                        Text("\(h)p").tag(h)
                    }
                }
                Picker("Аудио-кодек", selection: $settings.defaultAudioCodec) {
                    Text("MP3").tag(DownloadRequest.AudioCodec.mp3)
                    Text("M4A").tag(DownloadRequest.AudioCodec.m4a)
                }
            }

            authSection(store)
        }
        .formStyle(.grouped)
    }

    // MARK: - Authorization

    @ViewBuilder
    private func authSection(_ store: SettingsStore) -> some View {
        let sourceBinding = Binding(
            get: { store.authSourceKind },
            set: { store.setAuthSource($0) }
        )
        let browserBinding = Binding(
            get: { store.authBrowser },
            set: { store.setAuthBrowser($0) }
        )

        Section("Авторизация") {
            Picker("Источник", selection: sourceBinding) {
                Text("Нет").tag(SettingsStore.AuthSourceKind.none)
                Text("Cookies из браузера").tag(SettingsStore.AuthSourceKind.browser)
                Text("Файл cookies.txt").tag(SettingsStore.AuthSourceKind.file)
            }

            switch store.authSourceKind {
            case .none:
                Text("Скачивание только общедоступного контента.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .browser:
                Picker("Браузер", selection: browserBinding) {
                    Text("Safari").tag(AuthConfig.Browser.safari)
                    Text("Chrome").tag(AuthConfig.Browser.chrome)
                    Text("Firefox").tag(AuthConfig.Browser.firefox)
                    Text("Edge").tag(AuthConfig.Browser.edge)
                    Text("Brave").tag(AuthConfig.Browser.brave)
                    Text("Opera").tag(AuthConfig.Browser.opera)
                    Text("Vivaldi").tag(AuthConfig.Browser.vivaldi)
                    Text("Chromium").tag(AuthConfig.Browser.chromium)
                }
                Text("Залогиньтесь на сайт в выбранном браузере — grably использует "
                    + "вашу сессию. Система может запросить доступ (Safari — Full Disk "
                    + "Access, Chrome и др. — связку ключей).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .file:
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(store.authCookiesFile?.path ?? "Файл не выбран")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Выбрать…") { chooseCookiesFile(store) }
                }
                Text("Файл cookies.txt в формате Netscape, экспортированный из браузера.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseCookiesFile(_ settings: SettingsStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.text, .plainText]
        panel.allowsOtherFileTypes = true
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url {
            settings.setAuthCookiesFile(url)
        }
    }

    // MARK: - Engine

    private var engineTab: some View {
        let updater = environment.engineUpdater
        return Form {
            Section("Движок yt-dlp") {
                LabeledContent("Статус") {
                    switch environment.provisionState {
                    case .preparing:
                        Text("Подготовка…").foregroundStyle(.secondary)
                    case .ready:
                        Label("Готов", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed:
                        Label("Ошибка", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }

                LabeledContent("Версия") {
                    updaterStatus(updater.state)
                }

                HStack {
                    Spacer()
                    Button(updateButtonTitle(updater.state)) {
                        updater.checkAndUpdate()
                    }
                    .disabled(environment.provisionState != .ready || updater.isBusy)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The right-hand status line for the "Версия" row (spec §2.2).
    @ViewBuilder
    private func updaterStatus(_ state: EngineUpdateUIState) -> some View {
        switch state {
        case .unknown:
            Text("—").foregroundStyle(.secondary)
        case let .idle(current, latest):
            if let latest {
                HStack(spacing: 6) {
                    Text(current).foregroundStyle(.secondary)
                    Label("доступно \(latest)", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .imageScale(.small)
                        .foregroundStyle(.tint)
                }
            } else {
                HStack(spacing: 6) {
                    Text(current).foregroundStyle(.secondary)
                    Label("актуально", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .imageScale(.small)
                        .foregroundStyle(.green)
                }
            }
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Проверка…").foregroundStyle(.secondary)
            }
        case let .updating(target):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Обновление до \(target)…").foregroundStyle(.secondary)
            }
        case let .done(version):
            Label("Обновлено до \(version)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .error(message):
            Label("ошибка обновления", systemImage: "circle.fill")
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
                .foregroundStyle(.red)
                .help(message)
        }
    }

    private func updateButtonTitle(_ state: EngineUpdateUIState) -> String {
        switch state {
        case .idle(_, .some):
            return "Обновить"
        case .checking:
            return "Проверка…"
        case let .updating(target):
            return "Обновление до \(target)…"
        default:
            return "Проверить обновления"
        }
    }

    // MARK: - Folder picker

    private func chooseFolder(_ settings: SettingsStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.directoryURL = settings.downloadDirectory
        if panel.runModal() == .OK, let url = panel.url {
            settings.setDownloadDirectory(url)
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppEnvironment())
}
