import Foundation

enum SIPCallError: Error, LocalizedError {
    case dnsFailed(String)
    case noResponse(String)
    case rejected(code: Int, text: String)
    case authRequired(code: Int)
    case notAnswered(seconds: Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .dnsFailed(let h): return "DNS resolution failed for \(h)"
        case .noResponse(let s): return "No response from SIP server (\(s))"
        case .rejected(let c, let t): return "Call rejected: \(c) \(t)"
        case .authRequired(let c): return "Server requires auth (\(c)) — set Auth username/password"
        case .notAnswered(let s): return "Call not answered within \(s)s"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Outbound SIP UAC. Mirrors `SIPCall.place_call` from
/// `lkserver/sip_e2e_tester/src/sip_e2e_tester/sip/client.py`.
final class SIPCall: @unchecked Sendable {
    var config: SIPCallConfig

    var onWireLog: (@Sendable (WireLogEntry) -> Void)?
    var onStatus: (@Sendable (String) -> Void)?

    /// Fires once the call is answered and the RTP session is created.
    /// AppState uses this to wire mic capture and speaker playback.
    var onMediaReady: (@Sendable (RTPSession) -> Void)?

    /// Fires as the call ends — gives AppState a chance to tear down audio.
    var onMediaEnd: (@Sendable () -> Void)?

    let callID = SIPTokens.callID()
    let fromTag = SIPTokens.tag()
    private(set) var toTag: String = ""
    private(set) var branch = SIPTokens.branch()
    private(set) var cseq: Int = 1

    private(set) var sipTransport: SIPTransport?
    private(set) var rtpSocket: UDPSocket?

    private(set) var publicSIPIP: String = ""
    private(set) var publicSIPPort: UInt16 = 0
    private(set) var publicRTPIP: String = ""
    private(set) var publicRTPPort: UInt16 = 0

    private(set) var remoteRTPHost: String = ""
    private(set) var remoteRTPPort: UInt16 = 0
    private(set) var negotiatedPT: UInt8 = 0
    private(set) var negotiatedCodec: CodecKind = .pcmu
    private(set) var negotiatedDTMFPT: UInt8?

    private(set) var answered = false
    private(set) var hungup = false

    private var hangupRequested = false

    init(config: SIPCallConfig) {
        self.config = config
    }

    func requestHangup() {
        hangupRequested = true
    }

    /// Run the full call lifecycle. Synchronous-style: blocking I/O on the
    /// caller's thread. Caller should run inside a `Task.detached`.
    func run() throws {
        var cfg = config
        if cfg.localIP.isEmpty {
            cfg.localIP = try UDPSocket.detectLocalIP(targetHost: cfg.sipHost,
                                                     targetPort: cfg.sipPort)
        }
        if cfg.fromHost.isEmpty {
            cfg.fromHost = cfg.localIP
        }
        config = cfg

        // Build the SIP transport based on the chosen kind.
        let transport: SIPTransport
        switch cfg.transportKind {
        case .udp:
            transport = try UDPSIPTransport(targetHost: cfg.sipHost,
                                            targetPort: cfg.sipPort,
                                            localPort: cfg.localSIPPort)
        case .tcp, .tls:
            transport = try StreamSIPTransport(targetHost: cfg.sipHost,
                                               targetPort: cfg.sipPort,
                                               kind: cfg.transportKind,
                                               allowSelfSignedTLS: cfg.allowSelfSignedTLS)
        }
        try transport.start()
        let rtp = try UDPSocket(localPort: cfg.localRTPPort)
        self.sipTransport = transport
        self.rtpSocket = rtp
        emitInfo("SIP transport: \(cfg.transportKind.displayName) "
                 + "→ \(cfg.sipHost):\(cfg.sipPort), local "
                 + "\(transport.localIP.isEmpty ? cfg.localIP : transport.localIP):\(transport.localPort)")
        emitInfo("RTP local port \(rtp.localPort)")

        // STUN: only meaningful for the RTP socket and for UDP-SIP. With
        // TCP/TLS the server already sees our address via the connection
        // it accepted, and rport semantics don't apply.
        if cfg.useSTUN {
            emitStatus("STUN discovery…")
            let serverArg = cfg.stunServer.isEmpty ? nil : cfg.stunServer
            if cfg.transportKind == .udp,
               let socket = (transport as? UDPSIPTransport)?.socket,
               let r = STUN.discover(socket: socket, server: serverArg) {
                publicSIPIP = r.publicIP
                publicSIPPort = r.publicPort
                cfg.fromHost = r.publicIP
                config.fromHost = r.publicIP
                emitInfo("STUN SIP public address: \(r.publicIP):\(r.publicPort)")
            }
            if let r = STUN.discover(socket: rtp, server: serverArg) {
                publicRTPIP = r.publicIP
                publicRTPPort = r.publicPort
                emitInfo("STUN RTP public address: \(r.publicIP):\(r.publicPort)")
            }
        }
        if publicSIPIP.isEmpty {
            publicSIPIP = transport.localIP.isEmpty ? cfg.localIP : transport.localIP
            publicSIPPort = transport.localPort != 0 ? transport.localPort : cfg.localSIPPort
        }
        if publicRTPIP.isEmpty { publicRTPIP = cfg.localIP; publicRTPPort = cfg.localRTPPort }

        // INVITE phase
        let invite = buildInvite()
        emitStatus("Sending INVITE…")
        recordSent(method: "INVITE", raw: invite)
        try transport.send(Data(invite.utf8))

        let T1: TimeInterval = 0.5
        var retransmitInterval = T1
        var nextRetransmit = Date().addingTimeInterval(retransmitInterval)
        var timerBDeadline = Date().addingTimeInterval(64 * T1)
        var provisionalReceived = false
        var answerDeadline = Date().addingTimeInterval(cfg.answerTimeout)
        let needsRetransmit = cfg.transportKind.requiresRetransmits

        while !answered && Date() < answerDeadline && !hangupRequested {
            let receivedData: Data?
            do {
                receivedData = try transport.recvMessage(timeout: 0.25)
            } catch {
                emitError("recv error: \(error.localizedDescription)")
                continue
            }
            guard let data = receivedData else {
                let now = Date()
                if needsRetransmit && !provisionalReceived && now >= nextRetransmit {
                    if now >= timerBDeadline {
                        throw SIPCallError.noResponse("\(cfg.sipHost):\(cfg.sipPort)")
                    }
                    recordSent(method: "INVITE (retransmit)", raw: invite)
                    try transport.send(Data(invite.utf8))
                    retransmitInterval = min(retransmitInterval * 2, 4.0)
                    nextRetransmit = now.addingTimeInterval(retransmitInterval)
                }
                continue
            }

            guard let resp = SIPParser.parseResponse(data) else { continue }
            recordReceived(resp)

            let status = resp.statusCode
            if (100...199).contains(status) {
                provisionalReceived = true
                emitStatus("\(status) \(resp.statusText)")
            }
            if toTag.isEmpty,
               let to = resp.firstHeader("to"),
               let tag = SIPHeaders.tagParam(to) {
                toTag = tag
            }

            switch status {
            case 100, 180, 183:
                continue
            case 401, 407:
                guard !cfg.authPassword.isEmpty else {
                    throw SIPCallError.authRequired(code: status)
                }
                let ack = buildACK(toTag: SIPHeaders.tagParam(resp.firstHeader("to") ?? "") ?? "")
                recordSent(method: "ACK", raw: ack)
                try transport.send(Data(ack.utf8))

                let chHeader = (status == 401)
                    ? (resp.firstHeader("www-authenticate") ?? "")
                    : (resp.firstHeader("proxy-authenticate") ?? "")
                let authHeaderName = (status == 401) ? "Authorization" : "Proxy-Authorization"
                let challenge = SIPHeaders.parseAuthChallenge(chHeader)

                let authInvite = buildInviteWithAuth(authHeaderName: authHeaderName,
                                                     challenge: challenge)
                recordSent(method: "INVITE (auth)", raw: authInvite)
                try transport.send(Data(authInvite.utf8))

                provisionalReceived = false
                retransmitInterval = T1
                nextRetransmit = Date().addingTimeInterval(retransmitInterval)
                timerBDeadline = Date().addingTimeInterval(64 * T1)
                answerDeadline = Date().addingTimeInterval(cfg.answerTimeout)
                toTag = ""

            case 200:
                let ans = SDP.parseAnswer(resp.body)
                remoteRTPHost = ans.remoteHost
                remoteRTPPort = ans.remotePort
                negotiatedPT = ans.audioPT
                negotiatedCodec = ans.codec
                negotiatedDTMFPT = ans.dtmfPT

                let ack = buildACK(toTag: toTag)
                recordSent(method: "ACK", raw: ack)
                try transport.send(Data(ack.utf8))

                answered = true
                emitStatus("Connected — RTP \(remoteRTPHost):\(remoteRTPPort) PT=\(negotiatedPT) codec=\(negotiatedCodec.rtpmapName)")

            default:
                if status >= 400 {
                    throw SIPCallError.rejected(code: status, text: resp.statusText)
                }
            }
        }

        guard answered else {
            if hangupRequested {
                let cancel = buildCancel()
                recordSent(method: "CANCEL", raw: cancel)
                try? transport.send(Data(cancel.utf8))
                throw SIPCallError.cancelled
            }
            let cancel = buildCancel()
            recordSent(method: "CANCEL", raw: cancel)
            try? transport.send(Data(cancel.utf8))
            throw SIPCallError.notAnswered(seconds: Int(cfg.answerTimeout))
        }

        // Media phase: kick off RTP send/recv and notify the AppState so it
        // can wire up mic capture and speaker playback.
        let rtpSession = RTPSession(socket: rtp,
                                    remoteHost: remoteRTPHost,
                                    remotePort: remoteRTPPort,
                                    payloadType: negotiatedPT,
                                    codec: negotiatedCodec)
        rtpSession.dtmfPT = negotiatedDTMFPT
        onMediaReady?(rtpSession)
        rtpSession.startSending()
        rtpSession.startReceiving()
        defer {
            rtpSession.stop()
            onMediaEnd?()
        }

        let callEnd = Date().addingTimeInterval(cfg.callDuration)
        while !hungup && Date() < callEnd && !hangupRequested {
            let receivedData: Data?
            do {
                receivedData = try transport.recvMessage(timeout: 0.25)
            } catch {
                emitError("recv error: \(error.localizedDescription)")
                continue
            }
            guard let data = receivedData,
                  let either = SIPParser.parseMessage(data)
            else { continue }

            switch either {
            case .left(let req):
                recordReceivedRequest(req)
                if req.method == "BYE" {
                    let ok = build200OK(forRequest: req)
                    try? transport.send(Data(ok.utf8))
                    recordSent(method: "200 OK (to BYE)", raw: ok)
                    hungup = true
                    emitStatus("Remote hung up")
                }
            case .right(let resp):
                recordReceived(resp)
            }
        }

        if !hungup {
            let bye = buildBYE()
            recordSent(method: "BYE", raw: bye)
            try? transport.send(Data(bye.utf8))
            // Wait briefly for response
            for _ in 0..<8 {
                if let data = try? transport.recvMessage(timeout: 0.25),
                   let resp = SIPParser.parseResponse(data) {
                    recordReceived(resp)
                    break
                }
            }
            hungup = true
            emitStatus("Hung up")
        }
        transport.close()
    }

    // MARK: - Builders

    /// `Via: SIP/2.0/<transport> ip:port;branch=…[;rport]`. `rport` is
    /// only meaningful for UDP NAT traversal (RFC 3581); we omit it for
    /// stream transports.
    private func via(branch: String) -> String {
        let proto = config.transportKind.viaName
        let suffix = config.transportKind == .udp ? ";rport" : ""
        return "Via: SIP/2.0/\(proto) \(publicSIPIP):\(publicSIPPort);branch=\(branch)\(suffix)"
    }

    private func buildInvite() -> String {
        let cfg = config
        let toURI = cfg.toURI.isEmpty ? "sip:\(cfg.sipHost):\(cfg.sipPort)" : cfg.toURI
        let fromURI = "sip:\(cfg.fromUser)@\(cfg.fromHost)"
        let sipIP = publicSIPIP
        let sipPort = publicSIPPort
        let rtpIP = publicRTPIP
        let rtpPort = publicRTPPort
        let contactURI = "sip:\(cfg.fromUser)@\(sipIP):\(sipPort)"
        let sdp = SDP.buildAudioOffer(rtpHost: rtpIP, rtpPort: rtpPort, codecs: cfg.codecs)

        var s = ""
        s += "INVITE \(toURI) SIP/2.0\r\n"
        s += "\(via(branch: branch))\r\n"
        s += "Max-Forwards: 70\r\n"
        s += "From: \"\(cfg.fromDisplay)\" <\(fromURI)>;tag=\(fromTag)\r\n"
        s += "To: <\(toURI)>\r\n"
        s += "Call-ID: \(callID)\r\n"
        s += "CSeq: \(cseq) INVITE\r\n"
        s += "Contact: <\(contactURI)>\r\n"
        s += "Content-Type: application/sdp\r\n"
        s += "Allow: INVITE, ACK, BYE, CANCEL\r\n"
        s += "User-Agent: SIPClient-macOS/0.1.0\r\n"
        s += "Content-Length: \(sdp.utf8.count)\r\n"
        s += "\r\n"
        s += sdp
        return s
    }

    private func buildInviteWithAuth(authHeaderName: String,
                                     challenge: [String: String]) -> String {
        let cfg = config
        let toURI = cfg.toURI.isEmpty ? "sip:\(cfg.sipHost):\(cfg.sipPort)" : cfg.toURI
        let authUser = cfg.authUser.isEmpty ? cfg.fromUser : cfg.authUser
        let realm = challenge["realm"] ?? ""
        let nonce = challenge["nonce"] ?? ""
        let algorithm = challenge["algorithm"] ?? "MD5"

        let responseHash = DigestAuth.response(
            username: authUser, realm: realm, password: cfg.authPassword,
            nonce: nonce, method: "INVITE", uri: toURI
        )

        // New branch + bumped CSeq for the re-INVITE
        branch = SIPTokens.branch()
        cseq += 1

        let fromURI = "sip:\(cfg.fromUser)@\(cfg.fromHost)"
        let sipIP = publicSIPIP
        let sipPort = publicSIPPort
        let rtpIP = publicRTPIP
        let rtpPort = publicRTPPort
        let contactURI = "sip:\(cfg.fromUser)@\(sipIP):\(sipPort)"
        let sdp = SDP.buildAudioOffer(rtpHost: rtpIP, rtpPort: rtpPort, codecs: cfg.codecs)

        let authLine =
            "\(authHeaderName): Digest username=\"\(authUser)\"," +
            " realm=\"\(realm)\"," +
            " nonce=\"\(nonce)\"," +
            " uri=\"\(toURI)\"," +
            " response=\"\(responseHash)\"," +
            " algorithm=\(algorithm)\r\n"

        var s = ""
        s += "INVITE \(toURI) SIP/2.0\r\n"
        s += "\(via(branch: branch))\r\n"
        s += "Max-Forwards: 70\r\n"
        s += "From: \"\(cfg.fromDisplay)\" <\(fromURI)>;tag=\(fromTag)\r\n"
        s += "To: <\(toURI)>\r\n"
        s += "Call-ID: \(callID)\r\n"
        s += "CSeq: \(cseq) INVITE\r\n"
        s += "Contact: <\(contactURI)>\r\n"
        s += authLine
        s += "Content-Type: application/sdp\r\n"
        s += "Allow: INVITE, ACK, BYE, CANCEL\r\n"
        s += "User-Agent: SIPClient-macOS/0.1.0\r\n"
        s += "Content-Length: \(sdp.utf8.count)\r\n"
        s += "\r\n"
        s += sdp
        return s
    }

    private func buildACK(toTag: String) -> String {
        let cfg = config
        let toURI = cfg.toURI.isEmpty ? "sip:\(cfg.sipHost):\(cfg.sipPort)" : cfg.toURI
        let fromURI = "sip:\(cfg.fromUser)@\(cfg.fromHost)"
        let toHeader = toTag.isEmpty ? "<\(toURI)>" : "<\(toURI)>;tag=\(toTag)"

        var s = ""
        s += "ACK \(toURI) SIP/2.0\r\n"
        s += "\(via(branch: SIPTokens.branch()))\r\n"
        s += "Max-Forwards: 70\r\n"
        s += "From: \"\(cfg.fromDisplay)\" <\(fromURI)>;tag=\(fromTag)\r\n"
        s += "To: \(toHeader)\r\n"
        s += "Call-ID: \(callID)\r\n"
        s += "CSeq: \(cseq) ACK\r\n"
        s += "Content-Length: 0\r\n"
        s += "\r\n"
        return s
    }

    private func buildCancel() -> String {
        let cfg = config
        let toURI = cfg.toURI.isEmpty ? "sip:\(cfg.sipHost):\(cfg.sipPort)" : cfg.toURI
        let fromURI = "sip:\(cfg.fromUser)@\(cfg.fromHost)"

        var s = ""
        s += "CANCEL \(toURI) SIP/2.0\r\n"
        s += "\(via(branch: branch))\r\n"
        s += "Max-Forwards: 70\r\n"
        s += "From: \"\(cfg.fromDisplay)\" <\(fromURI)>;tag=\(fromTag)\r\n"
        s += "To: <\(toURI)>\r\n"
        s += "Call-ID: \(callID)\r\n"
        s += "CSeq: 1 CANCEL\r\n"
        s += "Content-Length: 0\r\n"
        s += "\r\n"
        return s
    }

    private func buildBYE() -> String {
        let cfg = config
        let toURI = cfg.toURI.isEmpty ? "sip:\(cfg.sipHost):\(cfg.sipPort)" : cfg.toURI
        let fromURI = "sip:\(cfg.fromUser)@\(cfg.fromHost)"
        cseq += 1
        let toHeader = toTag.isEmpty ? "<\(toURI)>" : "<\(toURI)>;tag=\(toTag)"

        var s = ""
        s += "BYE \(toURI) SIP/2.0\r\n"
        s += "\(via(branch: SIPTokens.branch()))\r\n"
        s += "Max-Forwards: 70\r\n"
        s += "From: \"\(cfg.fromDisplay)\" <\(fromURI)>;tag=\(fromTag)\r\n"
        s += "To: \(toHeader)\r\n"
        s += "Call-ID: \(callID)\r\n"
        s += "CSeq: \(cseq) BYE\r\n"
        s += "Content-Length: 0\r\n"
        s += "\r\n"
        return s
    }

    /// Build a 200 OK response to an in-dialog request (e.g., BYE) by echoing
    /// its Via, From, To, Call-ID, CSeq.
    private func build200OK(forRequest req: SIPRequest) -> String {
        let via = req.firstHeader("via") ?? ""
        let from = req.firstHeader("from") ?? ""
        let to = req.firstHeader("to") ?? ""
        let callid = req.firstHeader("call-id") ?? callID
        let cseqHdr = req.firstHeader("cseq") ?? "1 BYE"

        var s = ""
        s += "SIP/2.0 200 OK\r\n"
        s += "Via: \(via)\r\n"
        s += "From: \(from)\r\n"
        s += "To: \(to)\r\n"
        s += "Call-ID: \(callid)\r\n"
        s += "CSeq: \(cseqHdr)\r\n"
        s += "Content-Length: 0\r\n"
        s += "\r\n"
        return s
    }

    // MARK: - Wire log helpers

    private func recordSent(method: String, raw: String) {
        emit(.init(direction: .sent, kind: .sip,
                   summary: "→ \(method)",
                   detail: raw))
    }

    private func recordReceived(_ resp: SIPResponse) {
        let cseqMethod = (resp.firstHeader("cseq") ?? "")
            .split(separator: " ")
            .last
            .map { String($0) } ?? "?"
        emit(.init(direction: .received, kind: .sip,
                   summary: "← \(resp.statusCode) \(resp.statusText) (\(cseqMethod))",
                   detail: resp.raw))
    }

    private func recordReceivedRequest(_ req: SIPRequest) {
        emit(.init(direction: .received, kind: .sip,
                   summary: "← \(req.method)",
                   detail: req.raw))
    }

    private func emitStatus(_ s: String) {
        onStatus?(s)
        emit(.init(direction: .sent, kind: .info, summary: s, detail: nil))
    }

    private func emitInfo(_ s: String) {
        emit(.init(direction: .sent, kind: .info, summary: s, detail: nil))
    }

    private func emitError(_ s: String) {
        emit(.init(direction: .sent, kind: .error, summary: s, detail: nil))
    }

    private func emit(_ e: WireLogEntry) {
        onWireLog?(e)
    }
}
