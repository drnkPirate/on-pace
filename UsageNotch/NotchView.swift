import SwiftUI

struct NotchView: View {
    let store: UsageStore
    let cameraWidth: CGFloat
    let detailWidth: CGFloat
    let presentation: NotchPresentation
    let togglePin: () -> Void
    let openSettings: () -> Void
    let compactLayoutChanged: (CompactNotchLayout) -> Void

    private var expanded: Bool { presentation.expanded }
    private var pinned: Bool { presentation.pinned }
    private let secondary = Color.white.opacity(0.62)
    private let surface = Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255)

    var body: some View {
        let layout = EdgeLight.compactLayout(cameraWidth: cameraWidth, store: store)
        return TimelineView(.periodic(from: .now, by: expanded ? 1 : 5)) { timeline in
            ZStack(alignment: .top) {
                compact(at: timeline.date)
                    .frame(width: layout.width, height: NotchShape.compactHeight)
                    .offset(x: layout.centerOffset)
                    .opacity(expanded ? 0 : 1)
                    .animation(presentation.animates ? .easeOut(duration: 0.13).delay(expanded ? 0 : 0.07) : nil,
                               value: expanded)
                    .allowsHitTesting(!expanded)
                    .accessibilityHidden(expanded)

                details(at: timeline.date)
                    .frame(width: detailWidth, height: NotchShape.expandedHeight, alignment: .top)
                    .offset(y: expanded ? 0 : 8)
                    .opacity(expanded ? 1 : 0)
                    .animation(presentation.animates ? .easeOut(duration: expanded ? 0.19 : 0.11)
                        .delay(expanded ? 0.075 : 0) : nil, value: expanded)
                    .allowsHitTesting(expanded)
                    .accessibilityHidden(!expanded)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .monospacedDigit()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onChange(of: layout) { _, layout in compactLayoutChanged(layout) }
    }

    private func compact(at now: Date) -> some View {
        EdgeLight(store: store, now: now, animateHighlights: !expanded, action: togglePin)
            .opacity(presentation.showsLaunchMark ? 0 : 1)
            .overlay(alignment: .leading) {
                if presentation.showsLaunchMark {
                    TrailMark(size: 32, animateOnAppear: true)
                        .padding(.leading, EdgeLight.edgeInset)
                        .allowsHitTesting(false)
                }
            }
    }

    private func details(at now: Date) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: togglePin) {
                    HStack(spacing: 7) {
                        TrailMark(size: 22)
                        OnPaceWordmark(size: 14)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("On pace.")
                .accessibilityHint(pinned ? "Unpins the usage panel" : "Keeps the usage panel open")
                Spacer(minLength: 0)
                Text(syncStatus(at: now))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                control("arrow.clockwise", label: "Refresh usage", action: store.refresh)
                    .disabled(store.isRefreshing)
                control("gearshape", label: "Settings", action: openSettings)
                control(pinned ? "pin.fill" : "pin", label: "Pin usage panel", selected: pinned, action: togglePin)
                    .accessibilityValue(pinned ? "On" : "Off")
                    .accessibilityAddTraits(pinned ? .isSelected : [])
            }
            .foregroundStyle(secondary)
            .padding(.horizontal, 3)
            .frame(height: 34)

            HStack(alignment: .top, spacing: 16) {
                ForEach(Provider.allCases) { card($0, at: now) }
            }
            .padding(.top, 12)

            UsageHistoryView(snapshot: store.history)
                .frame(height: 234)
                .padding(.top, 12)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 20)
    }

    private func card(_ provider: Provider, at now: Date) -> some View {
        let state = store.state(for: provider)
        let reading = state.reading
        let stale = reading?.isStale(at: now) == true
        let activity = store.history?.values[provider]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ToolSymbol(provider: provider)
                    .frame(width: 26, height: 26)
                    .background(provider.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                Text(provider.name)
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let plan = reading?.plan {
                    Text(provider == .codex ? "ChatGPT \(plan)" : plan)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay { Capsule().strokeBorder(.white.opacity(0.15)) }
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer(minLength: 0)
                if let today = activity?.today, let value = today.apiValue {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(UsageFormat.euro(value))
                            .font(.system(size: 13, weight: .semibold))
                        Text(today.hasUnpricedUsage ? "Partial API value today" : "API value today")
                            .font(.system(size: 10))
                            .foregroundStyle(secondary)
                    }
                    .lineLimit(1)
                    .help("Estimated value of local tokens at standard API rates, converted to euros")
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(height: 32)

            VStack(alignment: .leading, spacing: 0) {
                if let session = reading?.session {
                    headline(session, provider: provider, stale: stale, now: now)
                        .padding(.bottom, 12)
                }
                if let reading {
                    ForEach(reading.otherLimits.prefix(2)) { limit in
                        quotaRow(limit, provider: provider)
                    }
                } else if case .unavailable(let reason, _) = state {
                    Text(reason.message(for: provider)).font(.system(size: 12)).foregroundStyle(secondary)
                }
            }
            .opacity(stale ? 0.4 : 1)
            .accessibilityHint(stale ? "Last known quota" : "")
            .frame(height: 168, alignment: .topLeading)
            .padding(.top, 14)

            Spacer(minLength: 0)
            ActivityChart(usage: activity, measuredAt: store.history?.at, tint: provider.tint)
                .frame(height: 77)
            if let activity {
                HStack(spacing: 8) {
                    metric("Tokens today", value: activity.today.tokens.formatted(.number.notation(.compactName).locale(UsageFormat.locale)),
                           help: "\(activity.today.tokens.formatted()) tokens, including cache")
                    metric("Sessions", value: activity.today.sessions.count.formatted(), help: "Local sessions with token usage today")
                    if let rate = activity.cacheHitRate {
                        metric("Cache hits", value: rate.formatted(.percent.precision(.fractionLength(0))),
                               help: "Share of input tokens served from cache")
                    }
                }
                .frame(height: 46)
                .padding(.top, 12)
            } else {
                Color.clear.frame(height: 58)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .frame(height: 402)
        .background(surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.07)).allowsHitTesting(false) }
    }

    private func headline(_ quota: QuotaWindow, provider: Provider, stale: Bool, now: Date) -> some View {
        let reached = quota.level == .reached && (quota.resetsAt.map { $0 > now } ?? true)
        return HStack(spacing: 17) {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.09), lineWidth: 8)
                if quota.fractionUsed > 0 {
                    Throb(enabled: reached && !stale && expanded) {
                        Circle()
                            .trim(from: 0, to: quota.fractionUsed)
                            .stroke(provider.tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(4)
                            .shadow(
                                color: provider.tint.opacity(quota.level == .normal || stale ? 0 : 0.60),
                                radius: reached ? 10 : 7
                            )
                    }
                }
                Text(quota.percentage).font(.system(size: 22, weight: .bold))
            }
            .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 5) {
                Text("5-hour session").font(.system(size: 12)).foregroundStyle(secondary)
                if let minutes = quota.minutesUntilReset(from: now) {
                    Text(minutes == 0 ? "Reset pending" :
                         "\(quota.level == .reached ? "Back in" : "Resets in") \(UsageFormat.duration(minutes))")
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                if !stale, let pace = quota.pace(at: now) {
                    let emphasis = pace != .comfortable
                    let ink = emphasis ? provider.tint : .white.opacity(0.75)
                    Label(pace.title, systemImage: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .foregroundStyle(ink)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(emphasis ? provider.tint.opacity(0.16) : .white.opacity(0.07), in: Capsule())
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 84)
        .accessibilityElement(children: .combine)
    }

    private func quotaRow(_ quota: QuotaWindow, provider: Provider) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text(quota.title).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 3)
                Text(quota.percentage).fontWeight(.semibold)
                if let reset = quota.resetsAt {
                    Text("· resets \(UsageFormat.weekday(reset)) \(UsageFormat.time(reset))")
                        .foregroundStyle(secondary)
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .minimumScaleFactor(0.83)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(provider.tint).frame(width: geometry.size.width * quota.fractionUsed)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
        .frame(height: 36, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    private func metric(_ label: String, value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(secondary)
            Text(value).font(.system(size: 14, weight: .semibold))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .help(help)
        .accessibilityElement(children: .combine)
    }

    private func control(_ icon: String, label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.77))
                .frame(width: 24, height: 24)
                .background(.white.opacity(selected ? 0.19 : 0.06), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func syncStatus(at now: Date) -> String {
        if store.isRefreshing { return "Syncing…" }
        guard let updated = store.lastUpdated ?? store.history?.at else { return "Waiting for data" }
        let elapsed = Int(max(0, now.timeIntervalSince(updated)))
        if elapsed < 60 { return "Synced \(elapsed)s ago" }
        if elapsed < 3600 { return "Synced \(elapsed / 60)m ago" }
        return "Synced at \(UsageFormat.time(updated))"
    }
}
