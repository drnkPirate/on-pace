import Darwin
import Foundation

struct UsageDay: Sendable {
    var tokens: Int64 = 0
    var sessions = Set<String>()
    var knownValue: Double?
    var hasUnpricedUsage = false

    var apiValue: Double? { knownValue ?? (hasUnpricedUsage ? nil : 0) }

    fileprivate mutating func include(_ event: TokenEvent) {
        tokens += event.tokens.total
        sessions.insert(event.session)
        if let value = event.apiValue {
            knownValue = (knownValue ?? 0) + value
        } else {
            hasUnpricedUsage = true
        }
    }
}

struct LocalUsage: Sendable {
    static let binCount = 20
    static let binLength: TimeInterval = 15 * 60

    let cacheHitRate: Double?
    let recent: [Int64]
    let daily: [UsageDay]

    var today: UsageDay { daily[daily.count - 1] }

    var peakBin: Int? {
        guard let peak = recent.max(), peak > 0 else { return nil }
        return recent.firstIndex(of: peak)
    }

    fileprivate init(events: [TokenEvent], days: [Date], now: Date, calendar: Calendar) {
        var recent = [Int64](repeating: 0, count: Self.binCount)
        var daily = Array(repeating: UsageDay(), count: days.count)
        var todayInput: Int64 = 0
        var todayCached: Int64 = 0
        let recentStart = now.addingTimeInterval(-Self.binLength * Double(Self.binCount))
        let dayIndex = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element, $0.offset) })

        for event in events where event.at >= days[0] && event.at <= now {
            guard let day = dayIndex[calendar.startOfDay(for: event.at)] else { continue }
            let usage = event.tokens
            daily[day].include(event)
            if event.at >= recentStart {
                let bin = Int(event.at.timeIntervalSince(recentStart) / Self.binLength)
                recent[min(bin, Self.binCount - 1)] += usage.total
            }
            if day == days.count - 1 {
                todayInput += usage.input
                todayCached += usage.cached
            }
        }

        self.cacheHitRate = todayInput == 0 ? nil : Double(todayCached) / Double(todayInput)
        self.recent = recent
        self.daily = daily
    }
}

struct LocalUsageSnapshot: Sendable {
    let values: [Provider: LocalUsage]
    let days: [Date]
    let at: Date
}

/// Each file contributes only token telemetry. Prompt text and paths are never stored in the snapshot.
actor LocalUsageReader {
    private var cache: [URL: MeteredFile] = [:]

    func read() async -> LocalUsageSnapshot {
        let cached = cache
        let (files, snapshot) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.scan(cached: cached))
            }
        }
        cache = files
        return snapshot
    }

    private static func scan(cached: [URL: MeteredFile]) -> ([URL: MeteredFile], LocalUsageSnapshot) {
        let now = Date.now
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let days = (-59...0).map { calendar.date(byAdding: .day, value: $0, to: today) ?? today }
        // Keep five rolling hours visible even when they cross midnight.
        let cutoff = days[0]
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var files: [URL: MeteredFile] = [:]
        var values: [Provider: LocalUsage] = [:]

        for provider in Provider.allCases {
            var events: [String: TokenEvent] = [:]
            for root in roots(for: provider) {
                guard let contents = fileManager.enumerator(
                    at: root, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let url as URL in contents where url.pathExtension == "jsonl" {
                    guard let attributes = try? url.resourceValues(forKeys: Set(keys)),
                          attributes.isRegularFile == true,
                          let modified = attributes.contentModificationDate, modified >= cutoff,
                          let size = attributes.fileSize else { continue }

                    let file: MeteredFile
                    if let existing = cached[url], existing.modified == modified, existing.size == size {
                        file = existing
                    } else {
                        guard let fresh = TranscriptMeter(provider: provider).read(url, since: cutoff) else { continue }
                        file = MeteredFile(modified: modified, size: size, events: fresh)
                    }
                    files[url] = file
                    for (key, event) in file.events {
                        if let previous = events[key] {
                            let origin = previous.at <= event.at ? previous : event
                            let complete = previous.tokens.total >= event.tokens.total ? previous : event
                            events[key] = TokenEvent(
                                at: origin.at, session: origin.session, tokens: complete.tokens, apiValue: complete.apiValue
                            )
                        } else {
                            events[key] = event
                        }
                    }
                }
            }
            if !events.isEmpty {
                values[provider] = LocalUsage(events: Array(events.values), days: days, now: now, calendar: calendar)
            }
        }
        return (files, LocalUsageSnapshot(values: values, days: days, at: now))
    }

    static func roots(for provider: Provider) -> [URL] {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch provider {
        case .claude:
            let base = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
            return [base.appendingPathComponent("projects")]
        case .codex:
            let base = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
            return [base.appendingPathComponent("sessions"), base.appendingPathComponent("archived_sessions")]
        }
    }
}

private struct MeteredFile: Sendable {
    let modified: Date
    let size: Int
    let events: [String: TokenEvent]
}

private struct TokenEvent: Sendable {
    let at: Date
    let session: String
    let tokens: TokenCounts
    let apiValue: Double?
}

private struct TranscriptMeter {
    let provider: Provider
    private let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private let plainTimestamp = Date.ISO8601FormatStyle()

    func read(_ url: URL, since cutoff: Date) -> [String: TokenEvent]? {
        guard let file = fopen(url.path, "r") else { return nil }
        var line: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer {
            free(line)
            fclose(file)
        }
        var events: [String: TokenEvent] = [:]
        let path = url.pathComponents
        var session = url.deletingPathExtension().lastPathComponent
        if provider == .claude, let subagents = path.lastIndex(of: "subagents"), subagents > 0 {
            session = path[subagents - 1]
        }
        var rootSession = session
        var started: Date?
        var inheritedThrough: Int?
        var model: String?
        var firstParty = true
        var previous: TokenCounts?
        var lineNumber = 0

        while true {
            let length = getline(&line, &capacity, file)
            guard length > 0, let line else { break }
            lineNumber += 1
            // A partially written line will be picked up after the file changes.
            guard line[length - 1] == 10, containsTelemetry(line),
                  let row = (try? JSONSerialization.jsonObject(with: Data(bytes: line, count: length))) as? [String: Any]
            else { continue }

            switch provider {
            case .claude:
                guard row["type"] as? String == "assistant",
                      let at = date(row["timestamp"]), at >= cutoff,
                      let message = row["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                let tokens = TokenCounts.claude(usage)
                guard tokens.total > 0 else { continue }
                let key = (message["id"] as? String) ?? (row["requestId"] as? String) ?? "\(url.path):\(lineNumber)"
                let counts = events[key].map { $0.tokens.maximum(tokens) } ?? tokens
                events[key] = TokenEvent(
                    at: events[key]?.at ?? at, session: rootSession, tokens: counts,
                    apiValue: StandardTokenRates.estimate(model: message["model"] as? String, tokens: counts)
                )

            case .codex:
                let kind = row["type"] as? String
                guard let payload = row["payload"] as? [String: Any] else { continue }
                if kind == "session_meta" {
                    session = (payload["id"] as? String) ?? session
                    rootSession = (payload["session_id"] as? String) ?? session
                    started = date(payload["timestamp"]) ?? date(row["timestamp"])
                    inheritedThrough = payload["subagent_history_start_ordinal"] as? Int
                    firstParty = (payload["model_provider"] as? String ?? "openai") == "openai"
                    model = payload["model"] as? String
                    continue
                }
                if kind == "turn_context" {
                    model = payload["model"] as? String ?? model
                    continue
                }
                guard kind == "event_msg", payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any],
                      total["input_tokens"] != nil, total["output_tokens"] != nil else { continue }
                let next = TokenCounts.codex(total)
                let delta: TokenCounts
                if let previous, next.input >= previous.input, next.output >= previous.output,
                   next.cached >= previous.cached, next.written >= previous.written {
                    delta = next.subtracting(previous)
                } else if let last = info["last_token_usage"] as? [String: Any] {
                    delta = TokenCounts.codex(last)
                } else { delta = next }
                previous = next
                guard delta.total > 0, let at = date(row["timestamp"]), at >= cutoff,
                      started.map({ at >= $0 }) ?? true,
                      inheritedThrough.map({ (row["ordinal"] as? Int ?? Int.max) > $0 }) ?? true else { continue }

                let key = "\(session):\(at.timeIntervalSince1970):\(next.total)"
                events[key] = TokenEvent(
                    at: at, session: rootSession, tokens: delta,
                    apiValue: firstParty ? StandardTokenRates.estimate(model: model, tokens: delta) : nil
                )
            }
        }
        return ferror(file) == 0 ? events : nil
    }

    private func containsTelemetry(_ line: UnsafePointer<CChar>) -> Bool {
        switch provider {
        case .claude: strstr(line, "\"assistant\"") != nil && strstr(line, "\"usage\"") != nil
        case .codex:
            strstr(line, "\"token_count\"") != nil || strstr(line, "\"turn_context\"") != nil ||
                strstr(line, "\"session_meta\"") != nil
        }
    }

    private func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return (try? timestamp.parse(value)) ?? (try? plainTimestamp.parse(value))
    }
}

struct TokenCounts: Sendable {
    let input: Int64
    let output: Int64
    let cached: Int64
    let written: Int64
    let longWrites: Int64

    var total: Int64 { input + output }

    fileprivate static func claude(_ raw: [String: Any]) -> Self {
        let read = number(raw, "cache_read_input_tokens")
        let write = number(raw, "cache_creation_input_tokens")
        let ttl = raw["cache_creation"] as? [String: Any] ?? [:]
        return Self(input: number(raw, "input_tokens") + read + write, output: number(raw, "output_tokens"),
                    cached: read, written: write, longWrites: min(write, number(ttl, "ephemeral_1h_input_tokens")))
    }

    fileprivate static func codex(_ raw: [String: Any]) -> Self {
        let input = number(raw, "input_tokens")
        let output = number(raw, "output_tokens")
        let reasoning = number(raw, "reasoning_output_tokens")
        let declaredTotal = number(raw, "total_tokens")
        // When total_tokens confirms that reasoning is separate, include it once.
        let billedOutput = reasoning > 0 && declaredTotal == input + output + reasoning ? output + reasoning : output
        let cached = min(input, number(raw, "cached_input_tokens"))
        return Self(input: input, output: billedOutput, cached: cached,
                    written: min(input - cached, number(raw, "cache_write_input_tokens")), longWrites: 0)
    }

    fileprivate func subtracting(_ prior: Self) -> Self {
        let freshInput = input - prior.input
        let freshCached = min(freshInput, cached - prior.cached)
        return Self(input: freshInput, output: output - prior.output, cached: freshCached,
                    written: min(freshInput - freshCached, written - prior.written), longWrites: 0)
    }

    fileprivate func maximum(_ other: Self) -> Self {
        Self(input: max(input, other.input), output: max(output, other.output),
             cached: max(cached, other.cached), written: max(written, other.written),
             longWrites: max(longWrites, other.longWrites))
    }

    private static func number(_ raw: [String: Any], _ key: String) -> Int64 {
        min(1_000_000_000_000, max(0, raw[key] as? Int64 ?? 0))
    }
}
