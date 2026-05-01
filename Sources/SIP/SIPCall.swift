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

    /// Fires the moment the first INVITE byte is on the wire. Callers
    /// use this as `t0` for call-timing metrics.
    var onInviteSent: (@Sendable () -> Void)?
    /// Fires for every 1xx (provisional) response — most importantly
    /// 100 Trying and 180 Ringing.
    var onProvisional: (@Sendable (Int) -> Void)?
    /// Fires when the 200 OK to the INVITE arrives (call answered).
    var onAnswered: (@Sendable () -> Void)?

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
    private(set) var negotiatedPtime: Int = 20
    private(set) var negotiatedDTMFPT: UInt8?

    /// Our SDES offer (used to encrypt outbound RTP). Generated once
    /// per call when `cfg.useSRTP` is true.
    private var outboundCrypto: SDPCryptoLine?
    /// Peer's SDES line from the answer (used to decrypt inbound RTP).
    private var inboundCrypto: SDPCryptoLine?

    private(set) var answered = false
    private(set) var hungup = false

    private var hangupRequested = false

    /// Remote target — the Contact URI from the 200 OK to INVITE. This
    /// is the Request-URI for in-dialog requests (ACK 2xx, BYE,
    /// re-INVITE) per RFC 3261 §12.2.1.1.
    private var remoteTarget: String = ""
    /// Route set — Record-Route values from the 200 OK to INVITE, in
    /// REVERSED order per RFC 3261 §12.1.2. routeSet[0] is the first
    /// hop to traverse for in-dialog requests.
    private var routeSet: [String] = []

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

        // Generate our outbound SRTP crypto if SDES is enabled. This
        // gets serialized into the SDP offer; the peer's matching line
        // in the answer fills `inboundCrypto`.
        if cfg.useSRTP {
            outboundCrypto = SDPCryptoLine.random()
        }
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
        onInviteSent?()

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
                onProvisional?(status)
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
                let ack = buildACKNon2xx(toTag: SIPHeaders.tagParam(resp.firstHeader("to") ?? "") ?? "")
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
                negotiatedPtime = ans.ptime
                negotiatedDTMFPT = ans.dtmfPT
                inboundCrypto = ans.crypto

                // Capture dialog routing info per RFC 3261 §12.1.2:
                //   - remote target = Contact URI from the 2xx
                //   - route set     = Record-Route reversed
                if let contactHdr = resp.firstHeader("contact") {
                    remoteTarget = SIPHeaders.extractURI(contactHdr)
                }
                if remoteTarget.isEmpty {
                    remoteTarget = cfg.toURI.isEmpty
                        ? "sip:\(cfg.sipHost):\(cfg.sipPort)"
                        : cfg.toURI
                }
                let recordRoutes = SIPHeaders.parseRecordRouteList(
                    resp.allHeaders("record-route"))
                routeSet = recordRoutes.reversed()

                let ack = buildACK2xx(toTag: toTag)
                let dst = routingTarget()
                recordSent(method: "ACK", raw: ack)
                try transport.send(Data(ack.utf8), to: dst.host, port: dst.port)

                answered = true
                onAnswered?()
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
        // SRTP keys: our offer for outbound, peer's answer for inbound.
        // If we offered SRTP but the peer answered without a crypto line,
        // we fall back to plain RTP for that direction.
        let outCrypto = (cfg.useSRTP && inboundCrypto != nil) ? outboundCrypto : nil
        let inCrypto = inboundCrypto
        if cfg.useSRTP {
            if outCrypto != nil && inCrypto != nil {
                emitInfo("SRTP enabled (\(outCrypto!.suite))")
            } else {
                emitInfo("SRTP requested but peer did not negotiate; using plain RTP")
            }
        }
        let rtpSession = RTPSession(socket: rtp,
                                    remoteHost: remoteRTPHost,
                                    remotePort: remoteRTPPort,
                                    payloadType: negotiatedPT,
                                    codec: negotiatedCodec,
                                    ptime: negotiatedPtime,
                                    outboundCrypto: outCrypto,
                                    inboundCrypto: inCrypto)
        rtpSession.dtmfPT = negotiatedDTMFPT
        onMediaReady?(rtpSession)
        rtpSession.startSending()
        rtpSession.startReceiving()
        defer {
            rtpSession.stop()
            onMediaEnd?()
        }

        // Stay in the call until the remote sends BYE or the user hits
        // Hang up. There's no client-side timeout.
        while !hungup && !hangupRequested {
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
                    let target = responseTarget(forRequest: req,
                                                fallback: (cfg.sipHost, cfg.sipPort))
                    try? transport.send(Data(ok.utf8),
                                        to: target.host, port: target.port)
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
            let dst = routingTarget()
            recordSent(method: "BYE", raw: bye)
            try? transport.send(Data(bye.utf8), to: dst.host, port: dst.port)
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

    /// Serialised user-defined headers ready to drop into a request,
    /// each terminated with CRLF. Skips empty rows. Header names get a
    /// quick sanitise — strip CR/LF/colon — so a malformed entry can't
    /// inject spurious headers.
    private func customHeadersBlock() -> String {
        var s = ""
        for h in config.customHeaders where h.isReadyToSend {
            let cleanName = h.name.replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces)
            let cleanValue = h.value.replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
            guard !cleanName.isEmpty else { continue }
            s += "\(cleanName): \(cleanValue)\r\n"
        }
        return s
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
        let sdp = SDP.buildAudioOffer(rtpHost: rtpIP, rtpPort: rtpPort,
                                      codecs: cfg.codecs,
                                      crypto: outboundCrypto)

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
        s += customHeadersBlock()
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
        let sdp = SDP.buildAudioOffer(rtpHost: rtpIP, rtpPort: rtpPort,
                                      codecs: cfg.codecs,
                                      crypto: outboundCrypto)

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
        s += customHeadersBlock()
        s += "Content-Length: \(sdp.utf8.count)\r\n"
        s += "\r\n"
        s += sdp
        return s
    }

    /// ACK for a non-2xx final response (401, 407, 4xx, 5xx, 6xx).
    /// Per RFC 3261 §17.1.1.3 it's part of the INVITE transaction —
    /// reuses the INVITE's branch and is sent hop-by-hop along the same
    /// path as the INVITE (no Route, Request-URI matches the INVITE).
    private func buildACKNon2xx(toTag: String) -> String {
        let cfg = config
        let toURI = cfg.toURI.isEmpty ? "sip:\(cfg.sipHost):\(cfg.sipPort)" : cfg.toURI
        let fromURI = "sip:\(cfg.fromUser)@\(cfg.fromHost)"
        let toHeader = toTag.isEmpty ? "<\(toURI)>" : "<\(toURI)>;tag=\(toTag)"

        var s = ""
        s += "ACK \(toURI) SIP/2.0\r\n"
        s += "\(via(branch: branch))\r\n"
        s += "Max-Forwards: 70\r\n"
        s += "From: \"\(cfg.fromDisplay)\" <\(fromURI)>;tag=\(fromTag)\r\n"
        s += "To: \(toHeader)\r\n"
        s += "Call-ID: \(callID)\r\n"
        s += "CSeq: \(cseq) ACK\r\n"
        s += "Content-Length: 0\r\n"
        s += "\r\n"
        return s
    }

    /// ACK to a 2xx INVITE response — separate transaction per RFC 3261
    /// §13.2.2.4. Request-URI is the dialog's remote target (Contact);
    /// route set is the reversed Record-Route from the 2xx.
    /// CSeq matches the INVITE; branch is fresh.
    private func buildACK2xx(toTag: String) -> String {
        let cfg = config
        let fromURI = "sip:\(cfg.fromUser)@\(cfg.fromHost)"
        let dialogTo = remoteDialogToURI()
        let toHeader = toTag.isEmpty ? "<\(dialogTo)>" : "<\(dialogTo)>;tag=\(toTag)"
        let routing = routeRequest()

        var s = ""
        s += "ACK \(routing.requestURI) SIP/2.0\r\n"
        s += "\(via(branch: SIPTokens.branch()))\r\n"
        s += "Max-Forwards: 70\r\n"
        for r in routing.routes {
            s += "Route: <\(r)>\r\n"
        }
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
        let fromURI = "sip:\(cfg.fromUser)@\(cfg.fromHost)"
        cseq += 1
        let dialogTo = remoteDialogToURI()
        let toHeader = toTag.isEmpty ? "<\(dialogTo)>" : "<\(dialogTo)>;tag=\(toTag)"
        let routing = routeRequest()

        var s = ""
        s += "BYE \(routing.requestURI) SIP/2.0\r\n"
        s += "\(via(branch: SIPTokens.branch()))\r\n"
        s += "Max-Forwards: 70\r\n"
        for r in routing.routes {
            s += "Route: <\(r)>\r\n"
        }
        s += "From: \"\(cfg.fromDisplay)\" <\(fromURI)>;tag=\(fromTag)\r\n"
        s += "To: \(toHeader)\r\n"
        s += "Call-ID: \(callID)\r\n"
        s += "CSeq: \(cseq) BYE\r\n"
        s += "Content-Length: 0\r\n"
        s += "\r\n"
        return s
    }

    // MARK: - Routing helpers (RFC 3261 §12.2.1.1, §18.2.2)

    /// The To-URI used inside the dialog. After the 2xx INVITE is
    /// parsed, the dialog's remote URI is the To header's URI; until
    /// then we fall back to the INVITE's target URI.
    private func remoteDialogToURI() -> String {
        let cfg = config
        if cfg.toURI.isEmpty {
            return "sip:\(cfg.sipHost):\(cfg.sipPort)"
        }
        return cfg.toURI
    }

    /// Compute (Request-URI, Route headers, send-to host:port) for an
    /// in-dialog request per RFC 3261 §12.2.1.1.
    ///
    ///   - Loose-routing (`;lr`) — the common case: Request-URI is the
    ///     remote target, Route headers carry the route set in order,
    ///     packet goes to the URI of the topmost Route (or to the
    ///     remote target if the route set is empty).
    ///   - Strict-routing (no `;lr`) — legacy: Request-URI is the
    ///     topmost route's URI, the remote target moves to the bottom
    ///     of the Route list, packet goes to that topmost route.
    private func routeRequest() -> (requestURI: String,
                                    routes: [String],
                                    host: String,
                                    port: UInt16) {
        let cfg = config
        let target = remoteTarget.isEmpty
            ? (cfg.toURI.isEmpty ? "sip:\(cfg.sipHost):\(cfg.sipPort)" : cfg.toURI)
            : remoteTarget
        let fallbackHost = cfg.sipHost
        let fallbackPort = cfg.sipPort

        if routeSet.isEmpty {
            let hp = SIPHeaders.hostPort(fromURI: target)
            return (target, [], hp?.host ?? fallbackHost, hp?.port ?? fallbackPort)
        }
        if SIPHeaders.hasLooseRouting(routeSet[0]) {
            let hp = SIPHeaders.hostPort(fromURI: routeSet[0])
            return (target, routeSet, hp?.host ?? fallbackHost, hp?.port ?? fallbackPort)
        }
        // Strict routing: pop top, append target to bottom.
        let newURI = routeSet[0]
        let routes = Array(routeSet.dropFirst()) + [target]
        let hp = SIPHeaders.hostPort(fromURI: newURI)
        return (newURI, routes, hp?.host ?? fallbackHost, hp?.port ?? fallbackPort)
    }

    /// Send-to address for an in-dialog request. Convenience wrapper
    /// around `routeRequest`.
    private func routingTarget() -> (host: String, port: UInt16) {
        let r = routeRequest()
        return (r.host, r.port)
    }

    /// Per RFC 3261 §18.2.2, derive the send-to address for a response
    /// from the request's topmost Via, honoring `received` / `rport`.
    private func responseTarget(forRequest req: SIPRequest,
                                fallback: (host: String, port: UInt16))
        -> (host: String, port: UInt16) {
        guard let via = req.firstHeader("via"),
              let target = SIPHeaders.responseTarget(fromTopmostVia: via)
        else {
            return fallback
        }
        return target
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
