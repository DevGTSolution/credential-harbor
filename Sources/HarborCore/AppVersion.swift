import Foundation

/// "Credential Harbor 1.4.0 (140)" from an Info.plist dictionary, so the Settings header always shows the build that is running.
public func versionLabel(_ info: [String: Any]?) -> String {
    guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else { return "Credential Harbor" }
    guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return "Credential Harbor \(short)" }
    return "Credential Harbor \(short) (\(build))"
}
