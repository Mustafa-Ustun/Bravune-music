import Foundation

struct PlanLimits: Equatable {
    var maxTracksPerMix: Int?
    var mixesPerDay: Int?
    var allowsProviderCounts: Bool
    var allowsAdvancedRules: Bool
    var allowsRandomMix: Bool
    var allowsSavedMixes: Bool
    var allowsAI: Bool
}

enum Plan: Int, CaseIterable, Identifiable, Comparable {
    case free
    case pro
    case proPlus

    var id: Int { rawValue }

    static func < (lhs: Plan, rhs: Plan) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .free: "Free"
        case .pro: "Pro"
        case .proPlus: "Pro+"
        }
    }

    var limits: PlanLimits {
        switch self {
        case .free:
            PlanLimits(
                maxTracksPerMix: 25,
                mixesPerDay: 3,
                allowsProviderCounts: false,
                allowsAdvancedRules: false,
                allowsRandomMix: false,
                allowsSavedMixes: false,
                allowsAI: false
            )
        case .pro:
            PlanLimits(
                maxTracksPerMix: nil,
                mixesPerDay: nil,
                allowsProviderCounts: true,
                allowsAdvancedRules: true,
                allowsRandomMix: true,
                allowsSavedMixes: true,
                allowsAI: false
            )
        case .proPlus:
            PlanLimits(
                maxTracksPerMix: nil,
                mixesPerDay: nil,
                allowsProviderCounts: true,
                allowsAdvancedRules: true,
                allowsRandomMix: true,
                allowsSavedMixes: true,
                allowsAI: true
            )
        }
    }
}
