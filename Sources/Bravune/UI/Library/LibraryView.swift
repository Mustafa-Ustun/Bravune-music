import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var state
    @State private var selection = Set<UnifiedTrack.ID>()

    var body: some View {
        Group {
            if state.library.isEmpty {
                ContentUnavailableView(
                    state.isRefreshing ? "Loading" : "No Tracks",
                    systemImage: "music.note",
                    description: Text(state.isRefreshing ? "Reading your music" : "Connect a provider to see your music")
                )
            } else {
                List(state.library, selection: $selection) { track in
                    TrackRow(track: track, isCurrent: state.player.currentTrack?.id == track.id)
                }
                .contextMenu(forSelectionType: UnifiedTrack.ID.self) { ids in
                    Button("Play Next") {
                        state.playNext(tracks(for: ids))
                    }
                    Button("Add to Queue") {
                        state.enqueue(tracks(for: ids))
                    }
                } primaryAction: { ids in
                    if let first = tracks(for: ids).first {
                        state.play(first, in: state.library)
                    }
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await state.refreshLibrary() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(state.isRefreshing)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = state.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
        }
    }

    private func tracks(for ids: Set<UnifiedTrack.ID>) -> [UnifiedTrack] {
        state.library.filter { ids.contains($0.id) }
    }
}
