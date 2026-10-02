import SwiftUI

struct PlaybackCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandMenu("Playback") {
            Button(state.player.isPlaying ? "Pause" : "Play") {
                state.player.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(state.queue.tracks.isEmpty)

            Button("Next") {
                state.player.next()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(state.queue.tracks.isEmpty)

            Button("Previous") {
                state.player.previous()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(state.queue.tracks.isEmpty)

            Divider()

            Button("Volume Up") {
                state.player.changeVolume(by: Player.volumeStep)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button("Volume Down") {
                state.player.changeVolume(by: -Player.volumeStep)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
        }
    }
}
