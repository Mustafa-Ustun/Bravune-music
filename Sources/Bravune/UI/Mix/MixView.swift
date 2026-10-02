import SwiftUI

struct MixView: View {
    @Environment(AppState.self) private var state
    @State private var deselected = Set<ProviderID>()
    @State private var trackCount = 20
    @State private var useCounts = false
    @State private var counts: [ProviderID: Int] = [:]
    @State private var randomize = true
    @State private var avoidArtists = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var isNaming = false
    @State private var draftName = ""
    @State private var aiPrompt = ""
    @State private var isAskingAI = false

    private var connected: [any ProviderAdapter] {
        state.connectedAdapters
    }

    private var selected: [ProviderID] {
        connected.map(\.id).filter { !deselected.contains($0) }
    }

    private var limits: PlanLimits {
        state.subscription.plan.limits
    }

    var body: some View {
        Group {
            if connected.isEmpty {
                ContentUnavailableView("No Providers", systemImage: "wand.and.stars", description: Text("Connect a provider to create a mix"))
            } else {
                Form {
                    Section("Providers") {
                        ForEach(connected, id: \.id) { adapter in
                            HStack {
                                Toggle(adapter.displayName, isOn: binding(for: adapter.id))
                                Spacer()
                                if useCounts && !deselected.contains(adapter.id) {
                                    Stepper(value: countBinding(for: adapter.id), in: 0...200) {
                                        Text("\(counts[adapter.id] ?? 5)")
                                            .monospacedDigit()
                                    }
                                    .fixedSize()
                                }
                            }
                        }
                    }
                    Section("Size") {
                        if useCounts {
                            Text("\(selected.reduce(0) { $0 + (counts[$1] ?? 5) }) tracks in total")
                        } else {
                            Stepper("Tracks: \(trackCount)", value: $trackCount, in: 1...500)
                        }
                    }
                    Section("Rules") {
                        Toggle(limits.allowsProviderCounts ? "Set tracks per provider" : "Set tracks per provider (Pro)", isOn: $useCounts)
                            .disabled(!limits.allowsProviderCounts)
                        Toggle("Randomize order", isOn: $randomize)
                        Toggle(limits.allowsAdvancedRules ? "Avoid repeating artists" : "Avoid repeating artists (Pro)", isOn: $avoidArtists)
                            .disabled(!limits.allowsAdvancedRules)
                    }
                    Section {
                        HStack {
                            Button("Create Mix", action: create)
                                .buttonStyle(.borderedProminent)
                                .disabled(selected.isEmpty)
                            Button(limits.allowsRandomMix ? "Random Mix" : "Random Mix (Pro)", action: createRandom)
                                .disabled(!limits.allowsRandomMix)
                            Button(limits.allowsSavedMixes ? "Save Mix" : "Save Mix (Pro)") {
                                draftName = ""
                                isNaming = true
                            }
                            .disabled(!limits.allowsSavedMixes || selected.isEmpty)
                            Spacer()
                            if let remaining = state.subscription.remainingMixes {
                                Text("\(remaining) mixes left today")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let message {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(messageIsError ? Color.red : Color.secondary)
                        }
                    }
                    aiSection
                    if limits.allowsSavedMixes {
                        savedSection
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Mix")
        .alert("Save Mix", isPresented: $isNaming) {
            TextField("Name", text: $draftName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this mix a name")
        }
    }

    private var aiSection: some View {
        Section(limits.allowsAI ? "AI Mix" : "AI Mix (Pro+)") {
            TextField("Describe the mix you want", text: $aiPrompt, axis: .vertical)
                .lineLimit(2...4)
                .disabled(!limits.allowsAI)
            HStack {
                Button("Create with AI", action: createWithAI)
                    .disabled(!limits.allowsAI || isAskingAI || aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isAskingAI {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private var savedSection: some View {
        Section("Saved Mixes") {
            if state.savedMixes.mixes.isEmpty {
                Text("No saved mixes yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(state.savedMixes.mixes) { mix in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mix.name)
                        Text(summary(of: mix.request))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Play") { run { try state.runSavedMix(mix) } }
                    Button("Edit") { load(mix.request) }
                    Button(role: .destructive) {
                        run(showsResult: false) { try state.deleteSavedMix(mix) }
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func summary(of request: MixRequest) -> String {
        let names = request.providers.map { id in
            state.adapterList.first { $0.id == id }?.displayName ?? id.rawValue
        }
        return "\(request.effectiveTrackCount) tracks · \(names.joined(separator: ", "))"
    }

    private func binding(for id: ProviderID) -> Binding<Bool> {
        Binding(
            get: { !deselected.contains(id) },
            set: { isOn in
                if isOn {
                    deselected.remove(id)
                } else {
                    deselected.insert(id)
                }
            }
        )
    }

    private func countBinding(for id: ProviderID) -> Binding<Int> {
        Binding(
            get: { counts[id] ?? 5 },
            set: { counts[id] = $0 }
        )
    }

    private func currentRequest() -> MixRequest {
        let providers = selected
        let distribution = useCounts
            ? Dictionary(uniqueKeysWithValues: providers.map { ($0.rawValue, counts[$0] ?? 5) })
            : [:]
        return MixRequest(
            providers: providers,
            trackCount: trackCount,
            providerDistribution: distribution,
            avoidDuplicateArtists: avoidArtists,
            randomize: randomize
        )
    }

    private func load(_ request: MixRequest) {
        deselected = Set(connected.map(\.id).filter { !request.providers.contains($0) })
        trackCount = max(request.trackCount, 1)
        useCounts = request.usesDistribution
        counts = Dictionary(uniqueKeysWithValues: request.providers.map { ($0, request.providerDistribution[$0.rawValue] ?? 5) })
        randomize = request.randomize
        avoidArtists = request.avoidDuplicateArtists
        messageIsError = false
        message = "Loaded the mix settings"
    }

    private func create() {
        let request = currentRequest()
        run { try state.generateMix(request) }
    }

    private func createRandom() {
        run { try state.generateRandomMix() }
    }

    private func createWithAI() {
        let text = aiPrompt
        isAskingAI = true
        Task {
            defer { isAskingAI = false }
            do {
                let output = try await state.generateAIMix(text)
                messageIsError = false
                var note = output.result.isShort
                    ? "Created \(output.result.tracks.count) of \(output.result.requested) tracks, not enough matching tracks"
                    : "Created a mix with \(output.result.tracks.count) tracks"
                if !output.plan.unsupported.isEmpty {
                    note += ". Not supported yet: " + output.plan.unsupported.joined(separator: ", ")
                }
                message = note
            } catch {
                messageIsError = true
                message = error.localizedDescription
            }
        }
    }

    private func save() {
        let request = currentRequest()
        let name = draftName
        run(showsResult: false) {
            try state.saveMix(named: name, request: request)
            messageIsError = false
            message = "Saved the mix"
        }
    }

    private func run(_ work: () throws -> MixResult) {
        do {
            let result = try work()
            messageIsError = false
            message = result.isShort
                ? "Created \(result.tracks.count) of \(result.requested) tracks, not enough matching tracks"
                : "Created a mix with \(result.tracks.count) tracks"
        } catch {
            messageIsError = true
            message = error.localizedDescription
        }
    }

    private func run(showsResult: Bool, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            messageIsError = true
            message = error.localizedDescription
        }
    }
}
