import SwiftUI

struct QueueView: View {
    @Environment(AppState.self) private var state
    @State private var selection = Set<Int>()

    var body: some View {
        let queue = state.queue
        Group {
            if queue.tracks.isEmpty {
                ContentUnavailableView("Queue Is Empty", systemImage: "list.number", description: Text("Play or add tracks from the Library"))
            } else {
                List(selection: $selection) {
                    ForEach(Array(queue.tracks.enumerated()), id: \.offset) { index, track in
                        TrackRow(track: track, isCurrent: queue.currentIndex == index)
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        let to = destination > from ? destination - 1 : destination
                        queue.move(from: from, to: to)
                        selection.removeAll()
                    }
                    .onDelete { offsets in
                        state.removeFromQueue(indices: Set(offsets))
                        selection.removeAll()
                    }
                }
                .onChange(of: queue.tracks.map(\.id)) {
                    selection.removeAll()
                }
                .onDeleteCommand {
                    state.removeFromQueue(indices: selection)
                    selection.removeAll()
                }
                .contextMenu(forSelectionType: Int.self) { indices in
                    Button("Remove from Queue") {
                        state.removeFromQueue(indices: indices)
                    }
                } primaryAction: { indices in
                    if let first = indices.first {
                        state.player.play(at: first)
                    }
                }
            }
        }
        .navigationTitle("Queue")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    queue.shuffle()
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .disabled(queue.tracks.count < 2)
                Button {
                    state.clearQueue()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(queue.tracks.isEmpty)
            }
        }
    }
}
