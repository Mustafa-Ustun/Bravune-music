import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var player = state.player

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ArtworkView(url: player.currentTrack?.artwork, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.displayTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Text(player.displaySubtitle(includeAlbum: false))
                        .font(.subheadline)
                        .foregroundStyle(player.visibleNotice == nil ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 28) {
                Spacer()
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill")
                }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                }
                Spacer()
            }
            .buttonStyle(.plain)
            .disabled(player.queue.tracks.isEmpty)

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Open Bravune") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit Bravune") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
