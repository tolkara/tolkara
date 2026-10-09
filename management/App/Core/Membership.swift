import Foundation
import Security

/// An Apple developer team this Mac knows about, and what we can tell about
/// its membership without asking for any credentials.
struct DeveloperTeam: Identifiable, Hashable, Codable {
    enum Kind: Int, Codable, Comparable {
        case unknown, free, expired, paid
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }
    var id: String          // the 10-character team ID
    var name: String
    var kind: Kind
    var evidence: String    // where we learned it, for the user
}

/// Finds the user's teams in what Xcode already keeps on this Mac:
/// - the team list Xcode stores for signed-in accounts (with a free-team flag);
/// - provisioning profiles Xcode downloaded: a paid membership's last a year,
///   a free Personal Team's seven days, and only a paid team gets the Network
///   Extension capability Tolkara needs.
/// Nothing is sent anywhere. The first build confirms the result for real.
enum MembershipScanner {
    static let teamID = /^[A-Z0-9]{10}$/

    static func scan() -> [DeveloperTeam] {
        var found: [DeveloperTeam] = []
        if let defaults = UserDefaults(suiteName: Toolchain.xcodeBundleIdentifier) {
            found += teams(fromXcodeDefaults: defaults.dictionaryRepresentation())
        }
        found += provisioningProfiles().compactMap { team(fromProfile: $0) }
        return merge(found)
    }

    /// The provisioning profiles Xcode downloaded to this Mac.
    static func provisioningProfiles() -> [[String: Any]] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"].flatMap { folder in
            let files = (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? []
            return files.filter { ["mobileprovision", "provisionprofile"].contains($0.pathExtension) }
                .compactMap { try? Data(contentsOf: $0) }.compactMap(decodeProfile)
        }
    }

    /// When the newest profile for an app runs out: after that the app no
    /// longer opens on the iPad until it is built and installed again.
    static func expiry(team: String, bundleID: String, in profiles: [[String: Any]]) -> Date? {
        profiles.filter { ($0["Entitlements"] as? [String: Any])?["application-identifier"] as? String == "\(team).\(bundleID)" }
            .compactMap { $0["ExpirationDate"] as? Date }.max()
    }

    /// Xcode's IDEProvisioningTeamByIdentifier (current) or IDEProvisioningTeams
    /// (older): account → [{teamID, teamName, isFreeProvisioningTeam, teamType}].
    static func teams(fromXcodeDefaults defaults: [String: Any]) -> [DeveloperTeam] {
        var result: [DeveloperTeam] = []
        for key in ["IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams"] {
            guard let accounts = defaults[key] as? [String: Any] else { continue }
            for case let list as [[String: Any]] in accounts.values {
                for entry in list {
                    guard let id = entry["teamID"] as? String, id.wholeMatch(of: teamID) != nil else { continue }
                    let free = (entry["isFreeProvisioningTeam"] as? Bool) ?? ((entry["isFreeProvisioningTeam"] as? NSNumber)?.boolValue ?? false)
                    let personal = (entry["teamType"] as? String)?.localizedCaseInsensitiveContains("personal") ?? false
                    result.append(DeveloperTeam(id: id, name: entry["teamName"] as? String ?? id,
                                                kind: free || personal ? .free : .paid, evidence: "Signed in to Xcode"))
                }
            }
        }
        return result
    }

    /// One provisioning profile's team and what its lifetime and entitlements say.
    static func team(fromProfile plist: [String: Any], now: Date = Date()) -> DeveloperTeam? {
        guard let id = (plist["TeamIdentifier"] as? [String])?.first, id.wholeMatch(of: teamID) != nil,
              let created = plist["CreationDate"] as? Date, let expires = plist["ExpirationDate"] as? Date else { return nil }
        let name = plist["TeamName"] as? String ?? id
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let paidOnly = entitlements.keys.contains { $0.hasPrefix("com.apple.developer.networking.networkextension") }
        let lifetime = expires.timeIntervalSince(created)
        let kind: DeveloperTeam.Kind
        if lifetime <= 8 * 86400 && !paidOnly { kind = .free }
        else if expires < now { kind = .expired }
        else { kind = .paid }
        return DeveloperTeam(id: id, name: name, kind: kind, evidence: "Provisioning profile")
    }

    /// One entry per team, keeping the strongest evidence.
    static func merge(_ teams: [DeveloperTeam]) -> [DeveloperTeam] {
        var best: [String: DeveloperTeam] = [:]
        for team in teams {
            if let current = best[team.id], current.kind >= team.kind { continue }
            best[team.id] = team
        }
        return best.values.sorted { ($0.kind, $1.name) > ($1.kind, $0.name) }
    }

    /// The property list inside a signed provisioning profile (CMS).
    static func decodeProfile(_ data: Data) -> [String: Any]? {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let status = data.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, data.count) }
        guard status == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return nil }
        return (try? PropertyListSerialization.propertyList(from: content as Data, format: nil)) as? [String: Any]
    }
}
