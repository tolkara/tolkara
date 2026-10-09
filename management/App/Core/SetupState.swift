import Foundation

enum SetupStep: String, CaseIterable, Identifiable, Codable {
    case welcome, membership, mac, iPad, game, install, copy, play
    /// Not a setup step: the games on the device, once Tolkara is there.
    case library
    var id: String { rawValue }

    /// The setup steps, in order.
    static let setup: [SetupStep] = [.welcome, .membership, .mac, .iPad, .game, .install, .copy, .play]

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .membership: "Developer Account"
        case .mac: "This Mac"
        case .iPad: "iPad or iPhone"
        case .game: "Game"
        case .install: "Install Tolkara"
        case .copy: "Copy Game"
        case .play: "Play"
        case .library: "Library"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .membership: "person.badge.key"
        case .mac: "laptopcomputer"
        case .iPad: "ipad.landscape"
        case .game: "gamecontroller"
        case .install: "square.and.arrow.down.on.square"
        case .copy: "externaldrive.badge.plus"
        case .play: "play.circle"
        case .library: "square.grid.2x2"
        }
    }
}

/// What the user set up, kept between launches in Application Support.
/// Device identifiers and the team stay on this Mac.
struct SetupState: Codable, Equatable {
    struct Acceptance: Codable, Equatable { var digest: String; var date: Date }
    struct Install: Codable, Equatable {
        var commit: String
        var team: String
        var bundleID: String
        var device: String
        var profiles: [String]
        var date: Date
        /// SHA-256 of each game's executable the build was made for: a game
        /// updated on the Mac needs a new build before it is copied.
        var executables: [String: String]?
    }
    struct Enrolment: Codable, Equatable { var bundleID: String; var device: String; var date: Date }
    struct Copy: Codable, Equatable { var bundleID: String; var device: String; var source: String; var date: Date }

    var welcomed = false
    var team: DeveloperTeam?
    var bundleID: String?
    var device: String?
    var deviceName: String?
    var deviceType: String?                     // "iPad" or "iPhone"
    var profiles: [String] = []                 // chosen, in order
    var sources: [String: String] = [:]         // profile → folder on this Mac
    var riskAccepted: [String: Acceptance] = [:]
    var installed: Install?
    var enrolled: Enrolment?
    var copied: [String: Copy] = [:]
    var sourceOverride: String?
    var checkForUpdates = true

    init() {}

    /// Every key is optional, so a state saved by an older or newer version
    /// keeps what it can instead of starting over.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        welcomed = try c.decodeIfPresent(Bool.self, forKey: .welcomed) ?? false
        team = try? c.decodeIfPresent(DeveloperTeam.self, forKey: .team)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        device = try c.decodeIfPresent(String.self, forKey: .device)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        deviceType = try c.decodeIfPresent(String.self, forKey: .deviceType)
        profiles = (try? c.decodeIfPresent([String].self, forKey: .profiles)) ?? []
        sources = (try? c.decodeIfPresent([String: String].self, forKey: .sources)) ?? [:]
        riskAccepted = (try? c.decodeIfPresent([String: Acceptance].self, forKey: .riskAccepted)) ?? [:]
        installed = try? c.decodeIfPresent(Install.self, forKey: .installed)
        enrolled = try? c.decodeIfPresent(Enrolment.self, forKey: .enrolled)
        copied = (try? c.decodeIfPresent([String: Copy].self, forKey: .copied)) ?? [:]
        sourceOverride = try c.decodeIfPresent(String.self, forKey: .sourceOverride)
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? true
    }

    var effectiveBundleID: String? { bundleID ?? team.map { LocalEnv.defaultBundleID(team: $0.id) } }

    static func load() -> SetupState {
        guard let data = try? Data(contentsOf: AppPaths.state) else { return SetupState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SetupState.self, from: data)) ?? SetupState()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) { try? data.write(to: AppPaths.state, options: .atomic) }
    }
}
