import SwiftUI

struct UsageHistoryView: View {
    let snapshot: LocalUsageSnapshot?
    @AppStorage("usageHistoryDays") private var selectedDays = 7
    private let secondary = Color.white.opacity(0.60)

    private var period: HistoryPeriod { HistoryPeriod(rawValue: selectedDays) ?? .week }

    var body: some View {
        let history = snapshot.map { UsageHistory(snapshot: $0, period: period) }
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text("History").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                if let history, let first = history.days.first, let last = history.days.last {
                    Text(dateSpan(first, last)).font(.system(size: 11)).foregroundStyle(secondary)
                }
                Spacer()
                Picker("History period", selection: $selectedDays) {
                    ForEach(HistoryPeriod.allCases) { range in
                        Text(range.title).tag(range.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            if let history {
                table(history)
                chart(history)
            } else {
                Text("Reading local history…")
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.07)).allowsHitTesting(false) }
    }

    private func table(_ history: UsageHistory) -> some View {
        VStack(spacing: 0) {
            tableLine("API value", "Tokens", "Sessions", "Active days", "vs prev.") { Text("Tool") }
                .font(.system(size: 10))
                .foregroundStyle(secondary)
                .frame(height: 20)

            ForEach(history.rows) { row in
                let total = row.provider == nil
                Rectangle().fill(.white.opacity(total ? 0.14 : 0.06)).frame(height: 1)
                tableLine(
                    row.current?.apiValue.map(UsageFormat.euro) ?? "—",
                    row.current?.tokens.formatted(.number.notation(.compactName)) ?? "—",
                    row.current?.sessions.formatted() ?? "—",
                    row.current.map { "\($0.active.count)/\(period.rawValue)" } ?? "—",
                    row.change.map { $0.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())) } ?? "—"
                ) {
                    HStack(spacing: 7) {
                        if let provider = row.provider {
                            RoundedRectangle(cornerRadius: 2).fill(provider.tint).frame(width: 8, height: 8)
                            Text(provider.name + (row.isPartial ? " · partial" : "")).fontWeight(.semibold)
                        } else {
                            Text(row.isPartial ? "Total · partial" : "Total").foregroundStyle(.white.opacity(0.82))
                        }
                    }
                }
                .font(.system(size: 11, weight: total ? .semibold : .regular))
                .frame(height: 28)
                .help(row.isPartial
                      ? "Partial estimate based on available local logs and model rates."
                      : "Estimated API value. Comparison uses retained logs from the preceding period.")
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func tableLine<Name: View>(
        _ cost: String, _ tokens: String, _ sessions: String, _ active: String, _ change: String,
        @ViewBuilder name: () -> Name
    ) -> some View {
        HStack(spacing: 6) {
            name().frame(width: 116, alignment: .leading)
            number(cost)
            number(tokens)
            number(sessions)
            number(active)
            number(change).foregroundStyle(secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.77)
    }

    private func number(_ value: String) -> some View {
        Text(value).frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func chart(_ history: UsageHistory) -> some View {
        let stacked = period == .month
        let peak: Int64 = max(1, history.days.indices.map { index in
            let counts = Provider.allCases.map { history.values[$0]?[index].tokens ?? 0 }
            return stacked ? counts.reduce(0, +) : counts.max() ?? 0
        }.max() ?? 0)
        return VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(history.days.indices, id: \.self) { index in
                    let today = index == history.days.count - 1
                    let description = Provider.allCases.compactMap { provider in
                        history.values[provider].map { "\(provider.name) \($0[index].tokens.formatted()) tokens" }
                    }.joined(separator: ", ")
                    dayBars(history, index: index, peak: peak, stacked: stacked)
                        .frame(maxWidth: .infinity)
                        .help("\(dateLabel(history.days[index])): \(description)")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(today ? "Today" : dateLabel(history.days[index]))
                        .accessibilityValue(description)
                }
            }
            .frame(height: 36, alignment: .bottom)

            if stacked, let first = history.days.first {
                HStack {
                    Text(dateLabel(first))
                    Spacer()
                    Text(dateLabel(history.days[history.days.count / 2]))
                    Spacer()
                    todayLabel
                }
                .font(.system(size: 10))
                .foregroundStyle(secondary)
            } else {
                HStack(spacing: 3) {
                    ForEach(history.days.indices, id: \.self) { index in
                        Group {
                            if index == history.days.count - 1 { todayLabel }
                            else { Text(UsageFormat.weekday(history.days[index])).foregroundStyle(secondary) }
                        }
                        .font(.system(size: 10))
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayBars(_ history: UsageHistory, index: Int, peak: Int64, stacked: Bool) -> some View {
        let alpha = index == history.days.count - 1 ? 1.0 : (stacked ? 0.70 : 0.60)
        if stacked {
            VStack(spacing: 0) {
                bar(.codex, count: history.values[.codex]?[index].tokens, peak: peak, opacity: alpha)
                bar(.claude, count: history.values[.claude]?[index].tokens, peak: peak, opacity: alpha)
            }
            .frame(maxWidth: .infinity, maxHeight: 36, alignment: .bottom)
        } else {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Provider.allCases) { provider in
                    bar(provider, count: history.values[provider]?[index].tokens, peak: peak, opacity: alpha)
                        .frame(width: 7)
                }
            }
            .frame(height: 36, alignment: .bottom)
        }
    }

    private func bar(_ provider: Provider, count: Int64?, peak: Int64, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(provider.tint.opacity(opacity))
            .frame(height: count.map { 36 * Double($0) / Double(peak) } ?? 0)
    }

    private var todayLabel: some View {
        Text("Today").fontWeight(.semibold).foregroundStyle(.white)
    }

    private func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "en_GB")))
    }

    private func dateSpan(_ first: Date, _ last: Date) -> String {
        let calendar = Calendar.current
        let leading = calendar.isDate(first, equalTo: last, toGranularity: .month)
            ? String(calendar.component(.day, from: first)) : dateLabel(first)
        return "\(leading) – \(dateLabel(last))"
    }
}
