import Foundation

/// A failure explained in plain words, with the setup step that fixes it.
struct Diagnosis: Equatable {
    var title: String
    var advice: String
    var step: SetupStep?
}

/// Recognises the common ways a build, install, enrolment or copy fails, from
/// the command output and the build log it names.
enum Diagnoser {
    private static let rules: [(patterns: [String], diagnosis: Diagnosis)] = [
        (["Personal development teams", "Personal Team", "does not support the Network Extensions capability",
          "free provisioning", "Cannot create a iOS App Development provisioning profile"],
         Diagnosis(title: "Your team cannot sign Tolkara",
                   advice: "Tolkara needs capabilities that only a paid Apple Developer Program membership can sign. Choose a team with a paid membership, or join the program.",
                   step: .membership)),
        (["No Accounts", "No account for team", "session has expired", "Sign in with your Apple", "account is not signed in",
          "requires a signed in", "Unable to log in with account"],
         Diagnosis(title: "Xcode is not signed in to your developer account",
                   advice: "Open Xcode › Settings › Apple Accounts, sign in with the Apple Account of your membership, then try again.",
                   step: .membership)),
        (["agree to the latest Program License Agreement", "Program License Agreement", "PLA Update available"],
         Diagnosis(title: "Apple needs you to accept an agreement",
                   advice: "Sign in at developer.apple.com/account and accept the latest Apple Developer Program License Agreement, then try again.",
                   step: .membership)),
        (["is already registered", "Failed Registering Bundle Identifier", "not available. Please enter a different string"],
         Diagnosis(title: "The app identifier is taken",
                   advice: "Apple registers an app identifier to one team only. Choose another one in Settings › Advanced, then try again.",
                   step: nil)),
        (["license agreements", "Xcode license", "xcodebuild -license", "runFirstLaunch"],
         Diagnosis(title: "Xcode is not set up yet",
                   advice: "Open Xcode once, accept its licence and let it install its components, then try again.",
                   step: .mac)),
        (["xcodegen: command not found", "xcodegen: No such file"],
         Diagnosis(title: "XcodeGen is missing", advice: "Install XcodeGen on the This Mac step, then try again.", step: .mac)),
        (["is locked", "kAMDMobileImageMounterDeviceLocked", "device was not, or could not be, unlocked"],
         Diagnosis(title: "Your device is locked", advice: "Unlock your iPad or iPhone and keep it unlocked until this step finishes, then try again.", step: nil)),
        (["Developer Mode", "developer mode is disabled"],
         Diagnosis(title: "Developer Mode is off", advice: "Turn on Developer Mode on your iPad or iPhone (see the iPad or iPhone step), then try again.", step: .iPad)),
        (["has not been explicitly trusted", "Untrusted Developer", "untrusted developer", "invalid code signature, inadequate entitlements"],
         Diagnosis(title: "Your device does not trust your developer certificate yet",
                   advice: "On your iPad or iPhone, open Settings › General › VPN & Device Management, tap your developer certificate and tap Trust. Then try again.",
                   step: nil)),
        (["No space left on device", "not enough space", "insufficient space", "kAMDNoSpaceError"],
         Diagnosis(title: "Not enough storage", advice: "Free up space on your iPad or iPhone, or on this Mac, then try again.", step: nil)),
        (["Unable to find a destination", "device not found", "No devices found", "is not connected", "device is not available",
          "The device is not paired", "ERROR: Could not connect"],
         Diagnosis(title: "Your iPad or iPhone is not reachable",
                   advice: "Connect it with a cable, unlock it and make sure it trusts this Mac (the iPad or iPhone step), then try again.",
                   step: .iPad)),
        (["Enrollment did not complete", "authorization-import-result", "Verified enrollment"],
         Diagnosis(title: "Connecting Tolkara to the developer service did not finish",
                   advice: "Unlock your iPad or iPhone, keep it connected and approve the prompt it shows, then try again.", step: nil)),
        (["Operation timed out", "Connection reset by peer"],
         Diagnosis(title: "The connection to your device dropped", advice: "Use a cable, keep the device unlocked and awake, then try again.", step: nil)),
    ]

    static func diagnose(_ output: String, source: URL?) -> Diagnosis? {
        var text = output
        // install.sh and other scripts name their full log: "BUILD FAILED -> logs/install-….log".
        if let match = output.firstMatch(of: /->\s*(\S+\.log)/), let root = source {
            let path = String(match.1)
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            if let log = try? String(contentsOf: url, encoding: .utf8) { text += "\n" + log.suffix(200_000) }
        }
        return rules.first { rule in rule.patterns.contains { text.localizedCaseInsensitiveContains($0) } }?.diagnosis
    }
}
