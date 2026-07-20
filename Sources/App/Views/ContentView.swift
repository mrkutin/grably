import SwiftUI
import GrablyCore

struct ContentView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        downloadsScreen
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar { toolbarContent }
            .navigationTitle("Grably")
            .navigationSubtitle("grab any video")
    }

    // MARK: - Downloads screen

    private var downloadsScreen: some View {
        @Bindable var viewModel = environment.downloadViewModel

        return VStack(spacing: 0) {
            banner

            VStack(alignment: .leading, spacing: 20) {
                URLInputView(
                    urlText: $viewModel.urlText,
                    probeState: viewModel.probeState,
                    onFetch: { viewModel.fetchNow() },
                    onCancelProbe: { viewModel.cancelProbe() }
                )

                topPanel(viewModel)
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                value: viewModel.probeState
            )
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            DownloadsListView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Banner

    @ViewBuilder
    private var banner: some View {
        switch environment.provisionState {
        case .preparing:
            PreparingBanner()
        case let .failed(message):
            HeaderBanner(message: message)
        case .ready:
            EmptyView()
        }
    }

    // MARK: - Top conditional panel

    @ViewBuilder
    private func topPanel(_ viewModel: DownloadViewModel) -> some View {
        switch viewModel.probeState {
        case .ready(let info):
            VStack(alignment: .leading, spacing: 16) {
                MediaPreviewView(info: info)
                FormatSelectionView(viewModel: viewModel)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(.regularMaterial)
            )
            .transition(panelTransition)
        case .error(let info):
            ErrorBanner(
                info: info,
                onClear: { viewModel.clearProbe() },
                onRetry: { viewModel.fetchNow() }
            )
            .transition(panelTransition)
        case .idle, .invalidURL, .probing:
            EmptyView()
        }
    }

    private var panelTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .top))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Настройки")
            .accessibilityLabel("Настройки")
        }
    }
}

#Preview {
    ContentView()
        .environment(AppEnvironment())
        .frame(width: 720, height: 560)
}
