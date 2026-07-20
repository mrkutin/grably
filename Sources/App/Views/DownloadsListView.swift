import SwiftUI
import GrablyCore

struct DownloadsListView: View {
    @Bindable var viewModel: DownloadViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if viewModel.tasks.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Загрузки")
                .font(.headline)
            Spacer()
            if hasFinished {
                Button("Очистить завершённые", action: viewModel.clearFinished)
                    .buttonStyle(.link)
                    .font(.subheadline)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var hasFinished: Bool {
        viewModel.tasks.contains { task in
            switch task.state {
            case .completed, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.tasks) { task in
                    DownloadRowView(
                        task: task,
                        onCancel: { viewModel.cancel(task) },
                        onRetry: { viewModel.retry(task) },
                        onRemove: { viewModel.remove(task) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Пока нет загрузок")
                .font(.headline)
            Text("Вставьте ссылку сверху, чтобы начать")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
