import Foundation

/// On-disk wire format for `.sipcall` profile shares.
///
/// A pretty-printed JSON document with a `version` envelope so we can
/// add fields (scenarios, audio clips, etc.) later without breaking
/// older readers. Newer fields use the existing forgiving decoders on
/// the underlying types (e.g. `DialerProfile.init(from:)`).
///
/// Note: passwords are never exported. The auth password lives only in
/// `DialerView` `@State` (memory-only) and never on `DialerProfile`,
/// so encoding the profile here cannot leak it.
struct SIPCallExport: Codable {
    static let currentVersion = 1

    var version: Int = SIPCallExport.currentVersion
    var profile: DialerProfile
    // Reserved for future expansion:
    // var scenarios: [Scenario]?
    // var clips: [ExportedClip]?

    /// Serialise a profile into the document format.
    static func encode(profile: DialerProfile) throws -> Data {
        let exp = SIPCallExport(profile: profile)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(exp)
    }

    /// Decode a `.sipcall` file. The original profile UUID is preserved
    /// — re-importing a previously exported profile cleanly updates the
    /// existing entry in the user's library rather than spawning a copy.
    /// Profiles imported from someone else's machine effectively get a
    /// "fresh" identity because their UUID doesn't already exist locally.
    static func decode(data: Data) throws -> DialerProfile {
        let dec = JSONDecoder()
        let exp = try dec.decode(SIPCallExport.self, from: data)
        return exp.profile
    }
}
