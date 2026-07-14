import Foundation

struct LoadingProgressPublicationState: Equatable, Sendable {
    enum Resolution: Equatable, Sendable {
        case stale
        case publish(Double?)
    }

    private(set) var generation: UInt = 0
    private(set) var isLoading = false
    private(set) var estimatedProgress = 0.0

    mutating func update(isLoading: Bool?, estimatedProgress: Double?) -> (generation: UInt, progress: Double?) {
        generation &+= 1
        if let isLoading { self.isLoading = isLoading }
        if let estimatedProgress { self.estimatedProgress = estimatedProgress }
        return (generation, currentProgress)
    }

    mutating func clear() {
        generation &+= 1
        isLoading = false
        estimatedProgress = 0
    }

    func resolve(generation expectedGeneration: UInt) -> Resolution {
        guard generation == expectedGeneration else { return .stale }
        return .publish(currentProgress)
    }

    private var currentProgress: Double? {
        guard isLoading else { return nil }
        guard estimatedProgress.isFinite else { return 0 }
        return max(0, min(estimatedProgress, 1))
    }
}
