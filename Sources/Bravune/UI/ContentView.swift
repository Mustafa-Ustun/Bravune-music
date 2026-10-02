import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case library = "Library"
    case queue = "Queue"
    case mix = "Mix"
    case providers = "Providers"
    case settings = "Settings"

    var id: String { rawValue }

    var shortcutKey: Character {
        Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1))
    }

    var icon: String {
        switch self {
        case .library: "music.note.list"
        case .queue: "list.number"
        case .mix: "wand.and.stars"
        case .providers: "externaldrive.connected.to.line.below"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $state.section) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            switch state.section ?? .library {
            case .library: LibraryView()
            case .queue: QueueView()
            case .mix: MixView()
            case .providers: ProvidersView()
            case .settings: SettingsView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
    }
}
