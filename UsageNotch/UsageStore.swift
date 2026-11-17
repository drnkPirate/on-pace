import Foundation
import Observation

@MainActor @Observable
final class UsageStore {
    private var states: [Provider: UsageState] = [:]
    private(set) var history: LocalUsageSnapshot?
    private let historyReader = LocalUsageReader()
    private(set) var isRefreshing = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var logsChangedDuringRead = false

    func state(for provider: Provider) -> UsageState {
        states[provider] ?? .loading
    }

    var lastUpdated: Date? {
        states.values.compactMap { $0.reading?.fetchedAt }.max()
    }

    func refresh() {
        refreshHistory()
        guard refreshTask == nil else { return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            await withTaskGroup(of: (Provider, Result<UsageReading, UsageFailure>).self) { group in
                for provider in Provider.allCases {
                    group.addTask {
                        let result = await withCheckedContinuation { continuation in
                            DispatchQueue.global(qos: .utility).async {
                                continuation.resume(returning: QuotaSources.read(provider))
                            }
                        }
                        return (provider, result)
                    }
                }
                for await (provider, result) in group {
                    guard let self else { continue }
                    switch result {
                    case .success(let reading):
                        self.states[provider] = .current(reading)
                    case .failure(let failure):
                        let previous = switch failure {
                        case .signInRequired, .noQuota: nil as UsageReading?
                        case .commandMissing, .timedOut, .unavailable: self.state(for: provider).reading
                        }
                        self.states[provider] = .unavailable(failure, previous: previous)
                    }
                }
            }
            self?.isRefreshing = false
            self?.refreshTask = nil
        }
    }

    func logsChanged() {
        if historyTask != nil {
            logsChangedDuringRead = true
        } else {
            refreshHistory(delay: .seconds(2))
        }
    }

    private func refreshHistory(delay: Duration = .zero) {
        guard historyTask == nil else { return }
        historyTask = Task { [weak self, historyReader] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self else { return }
            repeat {
                logsChangedDuringRead = false
                history = await historyReader.read()
                if logsChangedDuringRead { try? await Task.sleep(for: .seconds(2)) }
            } while logsChangedDuringRead
            historyTask = nil
        }
    }
}
