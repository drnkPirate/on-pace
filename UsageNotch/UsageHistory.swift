import Foundation

enum HistoryPeriod: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30

    var id: Self { self }
    var title: String { "\(rawValue) days" }
}

struct UsageHistory {
    struct Totals {
        var tokens: Int64 = 0
        var sessions = 0
        var active = Set<Int>()
        var knownValue: Double?
        var hasUnpriced = false

        var apiValue: Double? { knownValue ?? (hasUnpriced ? nil : 0) }

        mutating func merge(_ other: Self) {
            tokens += other.tokens
            sessions += other.sessions
            active.formUnion(other.active)
            if let value = other.knownValue { knownValue = (knownValue ?? 0) + value }
            hasUnpriced = hasUnpriced || other.hasUnpriced
        }
    }

    struct Row: Identifiable {
        let provider: Provider?
        let current: Totals?
        let previous: Totals?
        var incompleteCoverage = false

        var isPartial: Bool { incompleteCoverage || current?.hasUnpriced == true }

        var id: String { provider?.command ?? "total" }

        var change: Double? {
            guard !incompleteCoverage, let current, let previous, !current.hasUnpriced, !previous.hasUnpriced,
                  let currentValue = current.apiValue, let previousValue = previous.apiValue,
                  previousValue > 0 else { return nil }
            return (currentValue - previousValue) / previousValue
        }
    }

    let days: [Date]
    let values: [Provider: [UsageDay]]
    let rows: [Row]

    init(snapshot: LocalUsageSnapshot, period: HistoryPeriod, providers: [Provider] = Provider.allCases) {
        let count = period.rawValue
        let end = snapshot.days.count
        let currentRange = (end - count)..<end
        let previousRange = (end - 2 * count)..<(end - count)
        days = Array(snapshot.days[currentRange])
        values = snapshot.values.filter { providers.contains($0.key) }.mapValues { Array($0.daily[currentRange]) }
        let toolRows = providers.map { provider in
            let usage = snapshot.values[provider]
            return Row(
                provider: provider,
                current: usage.map { Self.summarize($0.daily[currentRange]) },
                previous: usage.map { Self.summarize($0.daily[previousRange]) }
            )
        }
        var current = Totals()
        var previous = Totals()
        for row in toolRows {
            if let totals = row.current { current.merge(totals) }
            if let totals = row.previous { previous.merge(totals) }
        }
        rows = toolRows + [Row(provider: nil, current: values.isEmpty ? nil : current,
                              previous: values.isEmpty ? nil : previous,
                              incompleteCoverage: !values.isEmpty && values.count < providers.count)]
    }

    private static func summarize(_ days: ArraySlice<UsageDay>) -> Totals {
        var result = Totals()
        var sessions = Set<String>()
        for (index, day) in days.enumerated() {
            result.tokens += day.tokens
            if day.tokens > 0 { result.active.insert(index) }
            if let value = day.knownValue { result.knownValue = (result.knownValue ?? 0) + value }
            result.hasUnpriced = result.hasUnpriced || day.hasUnpricedUsage
            sessions.formUnion(day.sessions)
        }
        result.sessions = sessions.count
        return result
    }
}
