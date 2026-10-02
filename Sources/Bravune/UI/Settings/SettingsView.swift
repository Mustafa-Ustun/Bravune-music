import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var keyDraft = ""

    var body: some View {
        @Bindable var subscription = state.subscription

        Form {
            Section("Plan") {
                Picker("Plan", selection: $subscription.plan) {
                    ForEach(Plan.allCases) { plan in
                        Text(plan.title).tag(plan)
                    }
                }
                .pickerStyle(.segmented)
                Text(summary(for: subscription.plan))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Claude API Key (Pro+ AI Mix)") {
                if state.hasAIKey {
                    HStack {
                        Text("A key is saved in your Keychain")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { state.clearAIKey() }
                    }
                } else {
                    HStack {
                        SecureField("sk-ant-...", text: $keyDraft)
                        Button("Save") {
                            state.setAIKey(keyDraft)
                            keyDraft = ""
                        }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private func summary(for plan: Plan) -> String {
        switch plan {
        case .free: "Basic mixes, up to 25 tracks, 3 mixes per day"
        case .pro: "Unlimited mixes and tracks, provider counts, artist rules, Random Mix, Saved Mixes"
        case .proPlus: "Everything in Pro plus AI playlists and smart queue"
        }
    }
}
