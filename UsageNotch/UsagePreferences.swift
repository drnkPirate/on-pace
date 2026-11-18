import Foundation
import Observation

@MainActor @Observable
final class UsagePreferences {
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var enabledProviders: [Provider]
    var opensOnHover: Bool {
        didSet { defaults.set(!opensOnHover, forKey: "opensOnClickOnly") }
    }
    var preferredDisplay: String {
        didSet {
            defaults.set(preferredDisplay.isEmpty ? nil : preferredDisplay, forKey: "preferredDisplay")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: "enabledProviders")
        let enabled = Provider.allCases.filter { saved?.contains($0.command) ?? true }
        enabledProviders = enabled.isEmpty ? Provider.allCases : enabled
        opensOnHover = !defaults.bool(forKey: "opensOnClickOnly")
        preferredDisplay = defaults.string(forKey: "preferredDisplay") ?? ""
    }

    func isEnabled(_ provider: Provider) -> Bool { enabledProviders.contains(provider) }

    func setEnabled(_ enabled: Bool, for provider: Provider) {
        guard enabled || enabledProviders.count > 1 else { return }
        enabledProviders = Provider.allCases.filter { $0 == provider ? enabled : isEnabled($0) }
        defaults.set(enabledProviders.map(\.command), forKey: "enabledProviders")
    }
}
