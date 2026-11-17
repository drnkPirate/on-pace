import SwiftUI

struct TrailMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var stopScale = 0.3
    let size: CGFloat
    var animateOnAppear = false

    static let lime = Color(red: TrailGeometry.lime.red, green: TrailGeometry.lime.green, blue: TrailGeometry.lime.blue)

    private var animated: Bool { animateOnAppear && !reduceMotion }

    var body: some View {
        let dots = size <= 22 ? TrailGeometry.small : TrailGeometry.full
        ZStack(alignment: .topLeading) {
            ForEach(dots.indices, id: \.self) { index in
                let dot = dots[index]
                let stop = index == dots.count - 1
                let bounds = dot.bounds(in: size)
                Circle()
                    .fill(stop ? Self.lime : .white)
                    .frame(width: bounds.width, height: bounds.height)
                    .opacity(stop || !animated || entered ? dot.opacity : 0)
                    .scaleEffect(stop && animated ? stopScale : 1)
                    .position(x: bounds.midX - (!stop && animated && !entered ? size * 0.12 : 0),
                              y: bounds.midY)
                    .animation(!stop && animated ? .easeOut(duration: 0.22).delay(Double(index) * 0.12) : nil,
                               value: entered)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task {
            guard animated else { return }
            entered = true
            do {
                try await Task.sleep(for: .milliseconds(360))
                withAnimation(.easeOut(duration: 0.13)) { stopScale = 1.14 }
                try await Task.sleep(for: .milliseconds(130))
                withAnimation(.easeInOut(duration: 0.11)) { stopScale = 1 }
            } catch {}
        }
    }
}

struct OnPaceWordmark: View {
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.05) {
            Text("On pace")
                .font(.system(size: size, weight: .bold))
                .tracking(-size * 0.025)
                .foregroundStyle(.white)
            Circle()
                .fill(TrailMark.lime)
                .frame(width: size * 0.21, height: size * 0.21)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.bottom] }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("On pace.")
    }
}

struct AboutOnPace: View {
    var body: some View {
        VStack(spacing: 5) {
            TrailMark(size: 128, animateOnAppear: true)
                .frame(height: 76)
            OnPaceWordmark(size: 28)
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("Version \(version)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.60))
                    .padding(.top, 6)
            }
        }
        .frame(width: 300, height: 182)
        .background(Color(red: 32 / 255, green: 41 / 255, blue: 35 / 255))
        .environment(\.colorScheme, .dark)
    }
}
