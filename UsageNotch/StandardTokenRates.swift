import Foundation

/// Public standard text-token rates in USD per million tokens.
/// Sources: platform.claude.com/docs/en/about-claude/pricing and developers.openai.com/api/docs/pricing.
enum StandardTokenRates {
    // ECB reference rate, 16 November 2026. One EUR buys this many USD.
    // https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/eurofxref-graph-usd.en.html
    private static let usdPerEuro = 1.1014
    private struct Rate {
        let input: Double
        let output: Double
        let cached: Double
        let write: Double
        let longWrite: Double

        init(_ input: Double, _ output: Double, _ cached: Double, write: Double? = nil, longWrite: Double? = nil) {
            self.input = input
            self.output = output
            self.cached = cached
            self.write = write ?? input * 1.25
            self.longWrite = longWrite ?? input * 2
        }
    }

    static func estimate(model: String?, tokens: TokenCounts) -> Double? {
        guard let model else { return nil }
        let id = model.replacingOccurrences(of: #"-(?:\d{8}|\d{4}-\d{2}-\d{2})$"#, with: "", options: .regularExpression)
        let rate: Rate
        let longerContext: Bool
        switch id {
        case "claude-opus-5-5": rate = Rate(4, 20, 0.20)
        case "claude-sonnet-5-5": rate = Rate(2, 10, 0.10)
        case "claude-sonnet-5": rate = Rate(2, 10, 0.20)
        case "claude-haiku-5-5":
            rate = tokens.input > 100_000 ? Rate(0.50, 2.50, 0.05) : Rate(0.10, 0.50, 0.01)
        case "claude-fable-5-1", "claude-mythos-5-1": rate = Rate(10, 50, 0.25)
        case "claude-fable-5-2", "claude-mythos-5-2": rate = Rate(8, 40, 0.20)
        case "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5":
            rate = Rate(5, 25, 0.50)
        case "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4": rate = Rate(3, 15, 0.30)
        case "claude-haiku-4-5": rate = Rate(1, 5, 0.10)
        case "gpt-6.1-sol": rate = Rate(2, 10, 0.10)
        case "gpt-6.1-terra": rate = Rate(1, 5, 0.05)
        case "gpt-6-astra": rate = Rate(10, 50, 1)
        case "gpt-6-luna": rate = Rate(0.10, 0.50, 0.01)
        case "gpt-6-sol": rate = Rate(2, 10, 0.20)
        case "gpt-5.6", "gpt-5.6-sol": rate = Rate(4, 20, 0.40)
        case "gpt-5.5": rate = Rate(5, 30, 0.50)
        case "gpt-5.4": rate = Rate(2.50, 15, 0.25)
        case "gpt-5.4-mini": rate = Rate(0.75, 4.50, 0.075)
        case "gpt-5.3-codex", "gpt-5.2-codex", "gpt-5.2": rate = Rate(1.75, 14, 0.175)
        default: return nil
        }

        switch id {
        case "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
             "gpt-5.6", "gpt-5.6-sol", "gpt-5.5", "gpt-5.4":
            longerContext = tokens.input > 272_000
        default: longerContext = false
        }
        let uncached = Double(max(0, tokens.input - tokens.cached - tokens.written))
        let shortWrites = Double(tokens.written - tokens.longWrites)
        let inputCost = uncached * rate.input + Double(tokens.cached) * rate.cached
            + shortWrites * rate.write + Double(tokens.longWrites) * rate.longWrite
        return (inputCost * (longerContext ? 2 : 1) + Double(tokens.output) * rate.output * (longerContext ? 1.5 : 1)) / (1_000_000 * usdPerEuro)
    }
}
