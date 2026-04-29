import Foundation

/// A named SIP trunk / target configuration. Stores everything the Dialer
/// needs except the auth password, which is kept only in memory.
struct DialerProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var sipHost: String
    var sipPort: UInt16
    var toURI: String
    var fromUser: String
    var fromDisplay: String
    var authUser: String
    var useSTUN: Bool
    var stunServer: String
    var localSIPPort: UInt16
    var localRTPPort: UInt16
    var callDuration: Double

    init(
        id: UUID = UUID(),
        name: String,
        sipHost: String = "",
        sipPort: UInt16 = 5060,
        toURI: String = "",
        fromUser: String = "sip-client",
        fromDisplay: String = "SIP Client",
        authUser: String = "",
        useSTUN: Bool = true,
        stunServer: String = "",
        localSIPPort: UInt16 = 5060,
        localRTPPort: UInt16 = 10000,
        callDuration: Double = 30
    ) {
        self.id = id
        self.name = name
        self.sipHost = sipHost
        self.sipPort = sipPort
        self.toURI = toURI
        self.fromUser = fromUser
        self.fromDisplay = fromDisplay
        self.authUser = authUser
        self.useSTUN = useSTUN
        self.stunServer = stunServer
        self.localSIPPort = localSIPPort
        self.localRTPPort = localRTPPort
        self.callDuration = callDuration
    }

    func callConfig(authPassword: String) -> SIPCallConfig {
        var cfg = SIPCallConfig(sipHost: sipHost.trimmingCharacters(in: .whitespaces))
        cfg.sipPort = sipPort
        cfg.toURI = toURI.trimmingCharacters(in: .whitespaces)
        cfg.fromUser = fromUser
        cfg.fromDisplay = fromDisplay
        cfg.authUser = authUser
        cfg.authPassword = authPassword
        cfg.useSTUN = useSTUN
        cfg.stunServer = stunServer
        cfg.localSIPPort = localSIPPort
        cfg.localRTPPort = localRTPPort
        cfg.callDuration = callDuration
        return cfg
    }
}
