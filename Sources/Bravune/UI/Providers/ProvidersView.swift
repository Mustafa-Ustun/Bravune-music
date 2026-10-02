import SwiftUI

struct ProvidersView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        List(state.visibleAdapters, id: \.id) { adapter in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(adapter.displayName)
                        .font(.headline)
                    Text(adapter.connectionDetail ?? "Not Connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let error = state.connectionErrors[adapter.id] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if state.connectingProviders.contains(adapter.id) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if adapter.isConnected {
                    Button("Change") {
                        Task { await state.connect(adapter) }
                    }
                    Button("Disconnect") {
                        Task { await state.disconnect(adapter) }
                    }
                } else {
                    Button("Connect") {
                        Task { await state.connect(adapter) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 6)
        }
        .navigationTitle("Providers")
    }
}
