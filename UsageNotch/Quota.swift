import Foundation

enum Provider: CaseIterable, Identifiable, Sendable {
    case claude, codex

    var id: Self { self }
    var name: String { self == .claude ? "Claude" : "Codex" }
    var command: String { self == .claude ? "claude" : "codex" }
}

struct QuotaWindow: Identifiable, Sendable {
    let id: String
    let title: String
    let used: Double
    let resetsAt: Date?
    let durationMinutes: Int?

    init?(_ id: String, title: String, used: Double?, resetsAt: Date?, durationMinutes: Int? = nil) {
        guard let used, used.isFinite, used >= 0 else { return nil }
        self.id = id
        self.title = title
        self.used = used
        self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
    }

    var fractionUsed: Double { min(used / 100, 1) }

    var level: QuotaLevel {
        if used >= 100 { return .reached }
        if used >= 80 { return .warning }
        return .normal
    }

    func minutesUntilReset(from now: Date) -> Int? {
        resetsAt.map { Int(max(0, $0.timeIntervalSince(now) / 60).rounded(.up)) }
    }

    func pace(at now: Date) -> QuotaPace? {
        guard durationMinutes == 300 else { return nil }
        if level == .reached { return .reached }
        guard let resetsAt, resetsAt > now else { return nil }
        let elapsed = 5 * 3600 - resetsAt.timeIntervalSince(now)
        guard elapsed >= 45 * 60 else { return nil }
        let projected = used * 5 * 3600 / elapsed
        if projected < 75 { return .comfortable }
        if projected >= 100 {
            let predicted = now.addingTimeInterval((100 - used) * elapsed / used)
            return .limitAt(predicted)
        }
        return .projected(Int(projected.rounded()))
    }

    var percentage: String {
        "\(min(used, 100).rounded(.down).formatted(.number.precision(.fractionLength(0))))%"
    }
}

enum QuotaPace: Equatable {
    case comfortable, projected(Int), limitAt(Date), reached

    var title: String {
        switch self {
        case .comfortable: "Well within limit"
        case .projected(let level): "On pace for ~\(level)% by reset"
        case .limitAt(let date): "On pace to hit limit ~\(UsageFormat.time(date))"
        case .reached: "Limit reached"
        }
    }
}

enum QuotaLevel {
    case normal, warning, reached
}

struct UsageReading: Sendable {
    let session: QuotaWindow?
    let otherLimits: [QuotaWindow]
    let plan: String?
    let fetchedAt: Date

    init?(windows: [QuotaWindow], plan: String?, fetchedAt: Date = .now) {
        guard !windows.isEmpty else { return nil }
        let session = windows.first { $0.id != "cloud" && $0.durationMinutes == 300 }
        self.session = session
        self.otherLimits = windows.filter { $0.id != session?.id }
        self.plan = plan
        self.fetchedAt = fetchedAt
    }

    var compactQuota: QuotaWindow? {
        session ?? otherLimits.first { $0.id != "cloud" && $0.durationMinutes == 10_080 }
    }

    func didResetCompactQuota(since previous: UsageReading) -> Bool {
        guard let oldWindow = previous.compactQuota,
              let newWindow = compactQuota,
              oldWindow.id == newWindow.id,
              oldWindow.durationMinutes == newWindow.durationMinutes,
              let oldReset = oldWindow.resetsAt,
              let newReset = newWindow.resetsAt else { return false }

        return fetchedAt > previous.fetchedAt && oldReset <= fetchedAt && newReset > fetchedAt
    }

    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) >= 300
    }
}

enum UsageFailure: Error, Sendable {
    case commandMissing, signInRequired, noQuota, timedOut, unavailable

    func message(for provider: Provider) -> String {
        switch self {
        case .commandMissing: "Install the \(provider.name) CLI."
        case .signInRequired: "Sign in with \(provider.command) in Terminal."
        case .noQuota: "No subscription quota reported."
        case .timedOut: "\(provider.name) did not respond."
        case .unavailable: "Could not refresh quota."
        }
    }
}

enum UsageState {
    case loading
    case current(UsageReading)
    case unavailable(UsageFailure, previous: UsageReading?)

    var reading: UsageReading? {
        switch self {
        case .loading: nil
        case .current(let reading), .unavailable(_, .some(let reading)): reading
        case .unavailable(_, .none): nil
        }
    }

    var isDisconnected: Bool {
        switch self {
        case .unavailable(.commandMissing, nil), .unavailable(.signInRequired, _), .unavailable(.noQuota, _):
            true
        default:
            false
        }
    }
}
