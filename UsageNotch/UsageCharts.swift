import SwiftUI

struct ActivityChart: View {
    let usage: LocalUsage?
    let measuredAt: Date?
    let tint: Color

    private var start: Date? { measuredAt?.addingTimeInterval(-5 * 3600) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity · last 5 hours")
                Spacer(minLength: 3)
                if let bin = usage?.peakBin, let start {
                    Text("Peak \(time(start.addingTimeInterval(Double(bin) * LocalUsage.binLength)))")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.64))
            .lineLimit(1)

            if let usage, let start {
                let peak = max(1, usage.recent.max() ?? 0)
                GeometryReader { geometry in
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(usage.recent.indices, id: \.self) { index in
                            let count = usage.recent[index]
                            let height = max(2, geometry.size.height * Double(count) / Double(peak))
                            let binStart = start.addingTimeInterval(Double(index) * LocalUsage.binLength)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(tint.opacity(count == 0 ? 0.25 : (index >= 16 ? 1 : 0.50)))
                                .frame(height: height)
                                .frame(maxWidth: .infinity)
                                .help("\(time(binStart)): \(count.formatted()) tokens")
                        }
                    }
                    .frame(height: geometry.size.height, alignment: .bottom)
                }
                .frame(height: 40)
                .accessibilityHidden(true)

                HStack {
                    Text(time(start))
                    Spacer()
                    Text(time(start.addingTimeInterval(2.5 * 3600)))
                    Spacer()
                    Text("now")
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.53))
                .accessibilityHidden(true)
            } else {
                Text(measuredAt == nil ? "Reading local usage…" : "No recent local usage")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func time(_ date: Date) -> String {
        UsageFormat.time(date)
    }
}
