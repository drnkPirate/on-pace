import SwiftUI

struct UsageHistoryView: View {
    let snapshot: LocalUsageSnapshot?
    var providers: [Provider] = Provider.allCases
    @AppStorage("usageHistoryDays") private var selectedDays = 7
    private let secondary = Color.white.opacity(0.60)

    private var period: HistoryPeriod { HistoryPeriod(rawValue: selectedDays) ?? .week }

    var body: some View {
        let history = snapshot.map { UsageHistory(snapshot: $0, period: period, providers: providers) }
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("History").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    if let history, let first = history.days.first, let last = history.days.last {
                        Text(dateSpan(first, last)).font(.system(size: 11)).foregroundStyle(secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                periodControl
            }

            if let history {
                table(history)
                chart(history)
            } else {
                Text("Reading local history…")
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
                    .frame(maxWidth: .infinity, minHeight: 166)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.07)).allowsHitTesting(false) }
    }

    private var periodControl: some View {
        HStack(spacing: 2) {
            ForEach(HistoryPeriod.allCases) { range in
                let selected = range == period
                Button {
                    selectedDays = range.rawValue
                } label: {
                    Text(range.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? .white : secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(.white.opacity(selected ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .frame(width: 150)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History period")
    }

    private func table(_ history: UsageHistory) -> some View {
        VStack(spacing: 0) {
            tableLine("API value", "Tokens", "Sessions", "Active days", "vs prev.") { Text("Tool") }
                .font(.system(size: 10))
                .foregroundStyle(secondary)
                .padding(.bottom, 6)

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
                .padding(.top, 7)
                .padding(.bottom, total ? 0 : 7)
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
        HistoryTableColumns {
            name().frame(maxWidth: .infinity, alignment: .leading)
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
            let counts = providers.map { history.values[$0]?[index].tokens ?? 0 }
            return stacked ? counts.reduce(0, +) : counts.max() ?? 0
        }.max() ?? 0)
        return VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: stacked ? 3 : 6) {
                ForEach(history.days.indices, id: \.self) { index in
                    let today = index == history.days.count - 1
                    let description = providers.compactMap { provider in
                        history.values[provider].map { "\(provider.name) \($0[index].tokens.formatted()) tokens" }
                    }.joined(separator: ", ")
                    VStack(spacing: 5) {
                        dayBars(history, index: index, peak: peak, stacked: stacked)
                            .frame(height: 36, alignment: .bottom)
                        if !stacked {
                            Group {
                                if today { todayLabel }
                                else { Text(UsageFormat.weekday(history.days[index])).foregroundStyle(secondary) }
                            }
                            .font(.system(size: 10))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(dateLabel(history.days[index])): \(description)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(today ? "Today" : dateLabel(history.days[index]))
                    .accessibilityValue(description)
                }
            }

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
            }
        }
    }

    @ViewBuilder
    private func dayBars(_ history: UsageHistory, index: Int, peak: Int64, stacked: Bool) -> some View {
        let alpha = index == history.days.count - 1 ? 1.0 : (stacked ? 0.70 : 0.60)
        if stacked {
            let activeProviders = providers.reversed().filter { (history.values[$0]?[index].tokens ?? 0) > 0 }
            let barHeight = 36 - CGFloat(max(0, providers.count - 1))
            VStack(spacing: 1) {
                ForEach(activeProviders) { provider in
                    bar(provider, count: history.values[provider]?[index].tokens, peak: peak,
                        height: barHeight, radius: 1.5, opacity: alpha)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(providers) { provider in
                    bar(provider, count: history.values[provider]?[index].tokens, peak: peak,
                        height: 36, radius: 2, opacity: alpha)
                        .frame(width: 7)
                }
            }
        }
    }

    private func bar(_ provider: Provider, count: Int64?, peak: Int64, height: CGFloat,
                     radius: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(provider.tint.opacity(opacity))
            .frame(height: height * CGFloat(count ?? 0) / CGFloat(peak))
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

private struct HistoryTableColumns: Layout {
    private let gap: CGFloat = 8
    private let weights: [CGFloat] = [1.4, 1, 1, 1, 1, 1]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let unit = zip(sizes, weights).map { $0.width / $1 }.max() ?? 0
        let idealWidth = weights.reduce(0, +) * unit + gap * CGFloat(weights.count - 1)
        return CGSize(width: proposal.width ?? idealWidth, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let unit = max(0, bounds.width - gap * CGFloat(weights.count - 1)) / weights.reduce(0, +)
        var x = bounds.minX
        for (column, weight) in zip(subviews, weights) {
            let width = weight * unit
            column.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                         proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + gap
        }
    }
}
