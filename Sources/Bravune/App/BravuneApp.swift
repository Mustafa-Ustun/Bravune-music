import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct BravuneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state: AppState
    @State private var spaceShortcut = SpaceBarShortcut()

    init() {
        let appState = AppState()
        _state = State(initialValue: appState)
        let shortcut = SpaceBarShortcut()
        shortcut.install { appState.player.togglePlayPause() }
        _spaceShortcut = State(initialValue: shortcut)
    }

    var body: some Scene {
        Window("Bravune", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            PlaybackCommands(state: state)
            NavigationCommands(state: state)
        }
        MenuBarExtra {
            MenuBarView()
                .environment(state)
        } label: {
            Image(systemName: "music.note")
        }
        .menuBarExtraStyle(.window)
    }
}
