import SwiftUI

struct PlayerBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var player = state.player
        let track = player.currentTrack

        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                HStack(spacing: 12) {
                    ArtworkView(url: track?.artwork, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.displayTitle)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text(player.displaySubtitle(includeAlbum: true))
                            .font(.caption)
                            .foregroundStyle(player.visibleNotice == nil ? Color.secondary : Color.orange)
                            .lineLimit(1)
                    }
                }
                .frame(width: 240, alignment: .leading)

                VStack(spacing: 4) {
                    HStack(spacing: 20) {
                        Button { player.previous() } label: { Image(systemName: "backward.fill") }
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 30))
                        }
                        Button { player.next() } label: { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                    .disabled(player.queue.tracks.isEmpty)

                    HStack(spacing: 8) {
                        Text(player.position.clock)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { min(player.position, duration(of: track)) },
                                set: { player.seek(to: $0) }
                            ),
                            in: 0...duration(of: track)
                        )
                        .disabled(track == nil)
                        .id("\(track?.id ?? "none")-\(player.state == .stopped)")
                        Text((track?.duration ?? 0).clock)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                    Slider(value: $player.volume, in: 0...1)
                        .frame(width: 100)
                }
                .frame(width: 140, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func duration(of track: UnifiedTrack?) -> Double {
        max(track?.duration ?? 1, 1)
    }
}
