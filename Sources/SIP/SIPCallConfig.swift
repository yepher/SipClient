import Foundation

struct SIPCallConfig {
    var sipHost: String
    var sipPort: UInt16 = 5060
    var toURI: String = ""

    var localIP: String = ""           // auto-detected if empty
    var localSIPPort: UInt16 = 5060
    var localRTPPort: UInt16 = 10000

    var useSTUN: Bool = true
    var stunServer: String = ""        // empty → default servers

    var fromDisplay: String = "SIP Client"
    var fromUser: String = "sip-client"
    var fromHost: String = ""

    var authUser: String = ""
    var authPassword: String = ""

    var answerTimeout: TimeInterval = 30
    var callDuration: TimeInterval = 30  // seconds to keep the call up after answer
}
