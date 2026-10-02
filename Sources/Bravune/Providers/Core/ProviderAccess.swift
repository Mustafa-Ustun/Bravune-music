import Foundation
import Observation

@MainActor
@Observable
final class ProviderAccess {
    private static let disabledKey = "bravune.providerAccess.disabled"

    private(set) var disabled: Set<ProviderID>

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        disabled = Set((defaults.stringArray(forKey: Self.disabledKey) ?? []).map(ProviderID.init(rawValue:)))
    }

    func isEnabled(_ id: ProviderID) -> Bool {
        !disabled.contains(id)
    }

    func setEnabled(_ id: ProviderID, _ enabled: Bool) {
        if enabled {
            disabled.remove(id)
        } else {
            disabled.insert(id)
        }
        defaults.set(disabled.map(\.rawValue).sorted(), forKey: Self.disabledKey)
    }
}
