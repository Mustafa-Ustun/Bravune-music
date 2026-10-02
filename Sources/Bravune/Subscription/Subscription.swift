import Foundation
import Observation

enum MixDenial: LocalizedError, Equatable {
    case dailyLimitReached(Int)
    case tooManyTracks(Int)
    case requires(Plan, String)

    var errorDescription: String? {
        switch self {
        case .dailyLimitReached(let limit): "The Free plan allows \(limit) mixes per day"
        case .tooManyTracks(let limit): "The Free plan allows up to \(limit) tracks per mix"
        case .requires(let plan, let feature): "\(feature) needs \(plan.title)"
        }
    }
}

@MainActor
@Observable
final class Subscription {
    private static let planKey = "bravune.subscription.plan"
    private static let dayKey = "bravune.subscription.mixDay"
    private static let countKey = "bravune.subscription.mixCount"

    var plan: Plan {
        didSet { defaults.set(plan.rawValue, forKey: Self.planKey) }
    }

    private(set) var mixesToday: Int

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        plan = Plan(rawValue: defaults.integer(forKey: Self.planKey)) ?? .free
        let today = Calendar.current.startOfDay(for: now()).timeIntervalSince1970
        mixesToday = defaults.double(forKey: Self.dayKey) == today ? defaults.integer(forKey: Self.countKey) : 0
    }

    var remainingMixes: Int? {
        plan.limits.mixesPerDay.map { max($0 - mixesToday, 0) }
    }

    func authorize(_ request: MixRequest) throws {
        let limits = plan.limits
        if let limit = limits.mixesPerDay, mixesToday >= limit {
            throw MixDenial.dailyLimitReached(limit)
        }
        if let limit = limits.maxTracksPerMix, request.effectiveTrackCount > limit {
            throw MixDenial.tooManyTracks(limit)
        }
        if request.usesDistribution && !limits.allowsProviderCounts {
            throw MixDenial.requires(.pro, "Provider counts")
        }
        if request.avoidDuplicateArtists && !limits.allowsAdvancedRules {
            throw MixDenial.requires(.pro, "Artist repetition rules")
        }
    }

    func authorizeRandomMix() throws {
        guard plan.limits.allowsRandomMix else { throw MixDenial.requires(.pro, "Random Mix") }
    }

    func authorizeAI() throws {
        guard plan.limits.allowsAI else { throw MixDenial.requires(.proPlus, "AI Mix") }
    }

    func authorizeSavedMixes() throws {
        guard plan.limits.allowsSavedMixes else { throw MixDenial.requires(.pro, "Saved Mixes") }
    }

    func recordMix() {
        let today = Calendar.current.startOfDay(for: now()).timeIntervalSince1970
        if defaults.double(forKey: Self.dayKey) != today {
            mixesToday = 0
        }
        mixesToday += 1
        defaults.set(today, forKey: Self.dayKey)
        defaults.set(mixesToday, forKey: Self.countKey)
    }
}
