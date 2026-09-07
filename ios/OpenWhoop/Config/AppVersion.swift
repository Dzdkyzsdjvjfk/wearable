import Foundation

/// The two numbers that tell Julian, from the phone alone, whether a sideload actually landed —
/// no cable, no Xcode. `shortVersion` is CFBundleShortVersionString (bumped in project.yml per
/// release); `build` is CFBundleVersion, which Xcode Cloud / the CI build stamps per run so even
/// two sideloads of the same marketing version are distinguishable.
enum AppVersion {
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// "1.0 (42)" — what the Settings row shows.
    static var displayString: String { "\(shortVersion) (\(build))" }
}
