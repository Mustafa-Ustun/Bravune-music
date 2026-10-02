import SwiftUI

struct NavigationCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(SidebarSection.allCases) { section in
                Button(section.rawValue) {
                    state.section = section
                }
                .keyboardShortcut(KeyEquivalent(section.shortcutKey), modifiers: .command)
            }
        }
    }
}
