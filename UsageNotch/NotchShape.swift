import AppKit
import SwiftUI

/// The visible outline is also the AppKit mouse hit region.
struct NotchShape: Shape {
    static let shoulderWidth: CGFloat = 12
    static let compactWidth: CGFloat = 360 + 2 * shoulderWidth
    static let compactHeight: CGFloat = 34
    static let expandedWidth: CGFloat = 712
    static let expandedHeight: CGFloat = 712
    static let shadowSide: CGFloat = 48
    static let shadowBottom: CGFloat = 84
    let progress: CGFloat

    func path(in rect: CGRect) -> Path {
        let bottom = rect.maxY
        let right = rect.maxX
        let s = min(Self.shoulderWidth, bottom / 2)
        let r = min(12 + 18 * progress, bottom - s)
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: right, y: 0))
        path.addQuadCurve(to: CGPoint(x: right - s, y: s), control: CGPoint(x: right - s, y: 0))
        path.addLine(to: CGPoint(x: right - s, y: bottom - r))
        path.addQuadCurve(to: CGPoint(x: right - s - r, y: bottom), control: CGPoint(x: right - s, y: bottom))
        path.addLine(to: CGPoint(x: s + r, y: bottom))
        path.addQuadCurve(to: CGPoint(x: s, y: bottom - r), control: CGPoint(x: s, y: bottom))
        path.addLine(to: CGPoint(x: s, y: s))
        path.addQuadCurve(to: .zero, control: CGPoint(x: s, y: 0))
        path.closeSubpath()
        return path
    }


}

struct CompactNotchLayout: Equatable {
    var width = NotchShape.compactWidth
    var centerOffset: CGFloat = 0
}

struct EdgeLight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: UsageStore
    let now: Date
    var animateHighlights = true
    let action: () -> Void

    private var connected: [Provider] {
        Provider.allCases.filter { !store.state(for: $0).isDisconnected }
    }

    private static let logoSize: CGFloat = 14
    private static let barWidth: CGFloat = 30
    private static let itemSpacing: CGFloat = 7
    private static let percentageSize: CGFloat = 12
    static let edgeInset: CGFloat = NotchShape.shoulderWidth + 16
    @MainActor
    static func compactLayout(cameraWidth: CGFloat, store: UsageStore) -> CompactNotchLayout {
        let font = NSFont.monospacedDigitSystemFont(ofSize: percentageSize, weight: .semibold)
        func percentageWidth(_ provider: Provider) -> CGFloat? {
            guard let percentage = store.state(for: provider).reading?.compactQuota?.percentage else { return nil }
            return ceil((percentage as NSString).size(withAttributes: [.font: font]).width)
        }
        let claude = percentageWidth(.claude)
        let codex = percentageWidth(.codex)
        let base = cameraWidth / 2 + edgeInset + logoSize + barWidth + 2 * itemSpacing + 2
        let left = base + (claude ?? codex ?? 0)
        let right = base + (codex ?? claude ?? 0)
        let width = max(NotchShape.compactWidth, left + right)
        let half = width / 2
        // Place the outline as close to centered as the two camera clearances allow.
        return CompactNotchLayout(width: width, centerOffset: min(half - left, max(0, right - half)))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                side(.claude)
                Spacer(minLength: 0)
                side(.codex)
            }
            .padding(.horizontal, Self.edgeInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilitySummary)
    }

    private func side(_ provider: Provider) -> some View {
        let left = provider == .claude
        let state = store.state(for: provider)
        return HStack(spacing: Self.itemSpacing) {
            if connected.contains(provider) {
                if left { ToolSymbol(provider: provider, size: Self.logoSize) }
                if let quota = state.reading?.compactQuota {
                    if !left { percentage(quota) }
                    bar(quota, provider: provider, alignment: left ? .leading : .trailing)
                    if left { percentage(quota) }
                }
                if !left { ToolSymbol(provider: provider, size: Self.logoSize) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .opacity(stale(provider) ? 0.4 : 1)
    }

    private func percentage(_ quota: QuotaWindow) -> some View {
        Text(quota.percentage)
            .font(.system(size: Self.percentageSize, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.90)
            .layoutPriority(1)
            .accessibilityHidden(true)
    }

    private func bar(_ quota: QuotaWindow, provider: Provider, alignment: Alignment) -> some View {
        let isStale = stale(provider)
        let reached = quota.level == .reached && (quota.resetsAt.map { $0 > now } ?? true)
        return ZStack(alignment: alignment) {
            Capsule().fill(.white.opacity(0.16))
            if quota.fractionUsed > 0 {
                Throb(enabled: reached && !isStale && animateHighlights) {
                    Capsule()
                        .fill(provider.tint)
                        .frame(width: max(2, Self.barWidth * quota.fractionUsed), height: 4)
                        .shadow(
                            color: provider.tint.opacity(quota.level == .normal || isStale ? 0 : 0.8),
                            radius: reached ? 8 : 5
                        )
                }
            }
        }
        .frame(width: Self.barWidth, height: 4)
        .overlay {
            if animateHighlights && !reduceMotion {
                ResetRipple(provider: provider, reset: store.compactQuotaResets[provider])
            }
        }
        .accessibilityHidden(true)
    }

    private func stale(_ provider: Provider) -> Bool {
        store.state(for: provider).reading?.isStale(at: now) == true
    }

    private var accessibilitySummary: String {
        let descriptions = connected.map { provider in
            guard let quota = store.state(for: provider).reading?.compactQuota else {
                return "\(provider.name) usage unavailable"
            }
            let age = stale(provider) ? ", last known reading" : ""
            let period = quota.durationMinutes == 300 ? "session" : "weekly limit"
            return "\(provider.name) \(quota.percentage) of \(period)\(age)"
        }
        return "AI usage: " + (descriptions.isEmpty ? "no readings" : descriptions.joined(separator: ", ")) + ". Show details"
    }
}

private struct ResetRipple: View {
    let provider: Provider
    let reset: Date?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let crest = width * 0.55
            KeyframeAnimator(initialValue: 1.0, trigger: reset) { progress in
                let distance = (width + crest) * (progress - 0.5)
                LinearGradient(colors: [.clear, provider.tint, .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: crest)
                    .offset(x: (width - crest) / 2 + (provider == .claude ? distance : -distance))
                    .opacity(0.85 * sin(.pi * progress))
            } keyframes: { _ in
                KeyframeTrack(\.self) {
                    MoveKeyframe(0.0)
                    LinearKeyframe(1.0, duration: 0.8)
                }
            }
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
    }
}

struct Throb<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let enabled: Bool
    var minimum = 0.55
    @ViewBuilder let content: () -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !enabled || reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2
            let fraction = (cos(2 * .pi * phase) + 1) / 2
            content().opacity(enabled && !reduceMotion ? minimum + (1 - minimum) * fraction : 1)
        }
    }
}

struct ToolSymbol: View {
    let provider: Provider
    var size: CGFloat = 14

    var body: some View {
        Text(provider == .claude ? "CL" : "CX")
            .font(.system(size: size * 0.64, weight: .bold))
            .foregroundStyle(provider.tint)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension Provider {
    var tint: Color {
        switch self {
        case .claude: Color(red: 224 / 255, green: 135 / 255, blue: 106 / 255)
        case .codex: Color(red: 127 / 255, green: 168 / 255, blue: 1)
        }
    }
}
