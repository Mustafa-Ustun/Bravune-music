import SwiftUI

struct TrackRow: View {
    let track: UnifiedTrack
    var isCurrent = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.artwork, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Text(track.isUnplayable ? "Can\u{2019}t be played \u{2014} damaged or unsupported file" : "\(track.artist) \u{2014} \(track.album)")
                    .font(.caption)
                    .foregroundStyle(track.isUnplayable ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(track.isUnplayable ? "\u{2014}" : track.duration.clock)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .opacity(track.isUnplayable ? 0.6 : 1)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.4))
                .foregroundStyle(.secondary)
        }
    }
}
