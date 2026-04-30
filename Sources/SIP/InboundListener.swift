import Foundation

/// UDP listener for inbound SIP. Owns one shared socket bound to the
/// configured local port; received SIP requests are dispatched to the
/// app via callbacks (new INVITEs and in-dialog requests for the
/// active call).
@MainActor
final class InboundListener: ObservableObject {
    @Published private(set) var isListening = false
    @Published var localPort: UInt16 = 5060
    @Published var lastError: String?

    /// Public-facing address advertised in our Contact / Via / SDP.
    /// Empty `publicHost` falls back to the locally-detected IPv4.
    /// `publicSIPPort` of 0 means "use the bound local port".
    /// `publicRTPPort` of 0 means "use the ephemeral RTP socket port".
    @Published var publicHost: String = ""
    @Published var publicSIPPort: UInt16 = 0
    @Published var publicRTPPort: UInt16 = 0

    /// STUN configuration. When `useSTUN` is on, the listener allocates
    /// its RTP socket on start, sends a STUN Binding Request, and uses
    /// the discovered public address for inbound SDP — no need for the
    /// user to fill in Public host / RTP port manually for cone NATs.
    @Published var useSTUN: Bool = true
    /// Empty = use STUN's default server list.
    @Published var stunServer: String = ""
    /// Local RTP port to bind. 0 = let the kernel pick an ephemeral port.
    @Published var localRTPPort: UInt16 = 0

    /// STUN result (public IP / port mapped for the RTP socket). Empty
    /// host means STUN hasn't run, was disabled, or failed.
    @Published private(set) var stunRTPHost: String = ""
    @Published private(set) var stunRTPPort: UInt16 = 0

    /// Detected local outbound IPv4 (set when start() succeeds).
    private(set) var detectedLocalIP: String = ""

    /// Fired on a new INVITE (no Call-ID match against an existing call).
    var onIncomingInvite: (@Sendable (SIPRequest, String, UInt16) -> Void)?
    /// Fired on any other SIP request (ACK / BYE / CANCEL …) — caller
    /// matches by Call-ID against the active call.
    var onInDialogRequest: (@Sendable (SIPRequest, String, UInt16) -> Void)?
    /// Wire-log surfaces.
    var onWireLog: (@Sendable (WireLogEntry) -> Void)?

    private var socket: UDPSocket?
    /// RTP socket pre-allocated at listener start so it can be STUN'd
    /// up front and reused across calls. Single-call concurrency for v1.
    private var rtpSocket: UDPSocket?
    private var listenTask: Task<Void, Never>?

    /// Shared socket exposed to InboundCall so responses go out the
    /// same UDP source the request arrived on.
    var sharedSocket: UDPSocket? { socket }
    var sharedRTPSocket: UDPSocket? { rtpSocket }

    func start() throws {
        guard !isListening else { return }
        let s = try UDPSocket(localPort: localPort)
        socket = s
        let rtp = try UDPSocket(localPort: localRTPPort)
        rtpSocket = rtp
        detectedLocalIP = (try? UDPSocket.detectLocalIP(
            targetHost: "8.8.8.8", targetPort: 53
        )) ?? "127.0.0.1"
        isListening = true
        lastError = nil

        // STUN-discover the RTP socket's public address before any
        // INVITE arrives. STUN.discover is blocking UDP I/O (up to a
        // few seconds across fallback servers), so we run it on a
        // detached task and only hop back to MainActor to publish the
        // result. Without this, `start()` froze the UI.
        stunRTPHost = ""
        stunRTPPort = 0
        if useSTUN {
            let server = stunServer.isEmpty ? nil : stunServer
            let log = onWireLog
            Task.detached { [weak self, rtp] in
                guard let result = STUN.discover(socket: rtp, server: server) else {
                    log?(.init(direction: .sent, kind: .info,
                               summary: "Inbound STUN: no response (NAT may not support it)"))
                    return
                }
                await self?.applySTUNResult(result)
                log?(.init(
                    direction: .sent, kind: .info,
                    summary: "Inbound STUN: RTP public \(result.publicIP):\(result.publicPort)"
                ))
            }
        }

        let onInvite = onIncomingInvite
        let onInDialog = onInDialogRequest
        let onLog = onWireLog
        listenTask = Task.detached(priority: .userInitiated) {
            await Self.listenLoop(socket: s,
                                  onInvite: onInvite,
                                  onInDialog: onInDialog,
                                  onLog: onLog)
        }
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
        socket = nil
        rtpSocket = nil
        isListening = false
        stunRTPHost = ""
        stunRTPPort = 0
    }

    /// Publish STUN result onto the listener's @Published fields and
    /// auto-fill blank manual overrides. Called from the detached STUN
    /// task once it returns; isolated to MainActor since the listener
    /// itself is.
    private func applySTUNResult(_ result: STUNResult) {
        stunRTPHost = result.publicIP
        stunRTPPort = result.publicPort
        if publicHost.isEmpty { publicHost = result.publicIP }
        if publicRTPPort == 0 { publicRTPPort = result.publicPort }
    }

    /// `nonisolated` is critical: without it the static func inherits
    /// `@MainActor` from the enclosing class, the `await` hops back
    /// onto MainActor, and `recvOnce`'s 0.5 s blocking poll freezes
    /// the UI every iteration.
    nonisolated private static func listenLoop(
        socket: UDPSocket,
        onInvite: (@Sendable (SIPRequest, String, UInt16) -> Void)?,
        onInDialog: (@Sendable (SIPRequest, String, UInt16) -> Void)?,
        onLog: (@Sendable (WireLogEntry) -> Void)?
    ) async {
        while !Task.isCancelled {
            let received: (data: Data, host: String, port: UInt16)?
            do {
                received = try socket.recvOnce(timeout: 0.5)
            } catch {
                continue
            }
            guard let r = received else { continue }
            guard let either = SIPParser.parseMessage(r.data) else { continue }
            switch either {
            case .left(let request):
                onLog?(.init(
                    direction: .received, kind: .sip,
                    summary: "← \(request.method) from \(r.host):\(r.port)",
                    detail: request.raw
                ))
                if request.method == "INVITE" {
                    onInvite?(request, r.host, r.port)
                } else {
                    onInDialog?(request, r.host, r.port)
                }
            case .right:
                // We're a UAS for the inbound flow — responses arriving
                // here are for an outgoing BYE we sent (peer ack); just
                // ignore for v1.
                break
            }
        }
    }
}

/// State machine for a single inbound SIP call (UAS). Sends provisional
/// + final responses, parses the offer SDP, builds the answer SDP, and
/// hands an `RTPSession` to the caller via `onAnswered`.
final class InboundCall: @unchecked Sendable {
    let invite: SIPRequest
    let sourceHost: String
    let sourcePort: UInt16
    private let socket: UDPSocket
    let rtpSocket: UDPSocket

    let toTag: String = SIPTokens.tag()
    let publicSIPHost: String
    let publicSIPPort: UInt16
    let publicRTPHost: String
    let publicRTPPort: UInt16

    var onWireLog: (@Sendable (WireLogEntry) -> Void)?
    var onAnswered: (@Sendable (RTPSession) -> Void)?
    var onEnded: (@Sendable () -> Void)?

    private(set) var answered = false
    private(set) var ended = false
    private var rtpSession: RTPSession?
    private var localCSeq: Int = 1

    init(invite: SIPRequest,
         sourceHost: String, sourcePort: UInt16,
         socket: UDPSocket, rtpSocket: UDPSocket,
         publicSIPHost: String, publicSIPPort: UInt16,
         publicRTPHost: String, publicRTPPort: UInt16) {
        self.invite = invite
        self.sourceHost = sourceHost
        self.sourcePort = sourcePort
        self.socket = socket
        self.rtpSocket = rtpSocket
        self.publicSIPHost = publicSIPHost
        self.publicSIPPort = publicSIPPort
        self.publicRTPHost = publicRTPHost
        self.publicRTPPort = publicRTPPort
    }

    var callID: String { invite.firstHeader("call-id") ?? "" }
    var fromHeader: String { invite.firstHeader("from") ?? "" }
    var toHeader: String { invite.firstHeader("to") ?? "" }

    var fromDisplay: String {
        let h = fromHeader
        if let q1 = h.firstIndex(of: "\""),
           let q2 = h[h.index(after: q1)...].firstIndex(of: "\"") {
            return String(h[h.index(after: q1)..<q2])
        }
        return ""
    }

    var fromURI: String {
        let h = fromHeader
        if let lt = h.firstIndex(of: "<"),
           let gt = h[lt...].firstIndex(of: ">") {
            return String(h[h.index(after: lt)..<gt])
        }
        return h.split(separator: ";").first.map(String.init) ?? h
    }

    var toURI: String {
        let h = toHeader
        if let lt = h.firstIndex(of: "<"),
           let gt = h[lt...].firstIndex(of: ">") {
            return String(h[h.index(after: lt)..<gt])
        }
        return h
    }

    // MARK: - Outgoing

    func sendProvisional(code: Int, reason: String) throws {
        let resp = buildResponse(code: code, reason: reason, sdp: nil)
        recordSent(method: "\(code) \(reason)", raw: resp)
        try socket.send(Data(resp.utf8), to: sourceHost, port: sourcePort)
    }

    func answer() throws {
        // Parse the offer that came in the INVITE body. We reuse
        // SDP.parseAnswer — it's symmetric for our purposes.
        let offer = SDP.parseAnswer(invite.body)
        let codec = offer.codec
        let codecPT = offer.audioPT
        let dtmfPT = offer.dtmfPT
        let ptime = offer.ptime

        let answerSDP = buildAnswerSDP(
            rtpHost: publicRTPHost,
            rtpPort: publicRTPPort,
            codec: codec, codecPT: codecPT,
            dtmfPT: dtmfPT, ptime: ptime
        )
        let resp = buildResponse(code: 200, reason: "OK", sdp: answerSDP)
        recordSent(method: "200 OK", raw: resp)
        try socket.send(Data(resp.utf8), to: sourceHost, port: sourcePort)

        // Build the RTP session pointing at the peer's m=/c= and start
        // it. Its receive loop will start delivering decoded PCM to
        // whichever onPlaybackPCM the host wires up.
        let rtp = RTPSession(
            socket: rtpSocket,
            remoteHost: offer.remoteHost,
            remotePort: offer.remotePort,
            payloadType: codecPT,
            codec: codec,
            ptime: ptime
        )
        rtp.dtmfPT = dtmfPT
        self.rtpSession = rtp
        answered = true
        onAnswered?(rtp)
    }

    func reject(code: Int = 486, reason: String = "Busy Here") throws {
        let resp = buildResponse(code: code, reason: reason, sdp: nil)
        recordSent(method: "\(code) \(reason)", raw: resp)
        try socket.send(Data(resp.utf8), to: sourceHost, port: sourcePort)
        ended = true
        onEnded?()
    }

    /// Send BYE to terminate an active call from our side.
    func hangup() throws {
        let bye = buildBYE()
        recordSent(method: "BYE", raw: bye)
        try socket.send(Data(bye.utf8), to: sourceHost, port: sourcePort)
        ended = true
        rtpSession?.stop()
        onEnded?()
    }

    /// Handle an in-dialog request (ACK / BYE / CANCEL) routed in by
    /// the listener. Returns true if it belonged to this call.
    func handleInDialogRequest(_ req: SIPRequest, from host: String, port: UInt16) -> Bool {
        guard req.firstHeader("call-id") == callID else { return false }
        switch req.method {
        case "ACK":
            recordReceived(req)
        case "BYE":
            let ok = buildResponseEcho(req: req, code: 200, reason: "OK")
            try? socket.send(Data(ok.utf8), to: host, port: port)
            recordSent(method: "200 OK (to BYE)", raw: ok)
            ended = true
            rtpSession?.stop()
            onEnded?()
        case "CANCEL":
            let ok = buildResponseEcho(req: req, code: 200, reason: "OK")
            try? socket.send(Data(ok.utf8), to: host, port: port)
            recordSent(method: "200 OK (to CANCEL)", raw: ok)
            if !answered {
                let term = buildResponse(code: 487,
                                         reason: "Request Terminated",
                                         sdp: nil)
                try? socket.send(Data(term.utf8),
                                 to: sourceHost, port: sourcePort)
                recordSent(method: "487 Request Terminated", raw: term)
                ended = true
                onEnded?()
            }
        default:
            break
        }
        return true
    }

    // MARK: - Builders

    private func buildResponse(code: Int, reason: String, sdp: String?) -> String {
        let via = invite.firstHeader("via") ?? ""
        let from = invite.firstHeader("from") ?? ""
        var to = invite.firstHeader("to") ?? ""
        if SIPHeaders.tagParam(to) == nil {
            to += ";tag=\(toTag)"
        }
        let callid = invite.firstHeader("call-id") ?? ""
        let cseq = invite.firstHeader("cseq") ?? "1 INVITE"

        var s = ""
        s += "SIP/2.0 \(code) \(reason)\r\n"
        s += "Via: \(via)\r\n"
        s += "From: \(from)\r\n"
        s += "To: \(to)\r\n"
        s += "Call-ID: \(callid)\r\n"
        s += "CSeq: \(cseq)\r\n"
        if (200..<300).contains(code) {
            s += "Contact: <sip:\(publicSIPHost):\(publicSIPPort)>\r\n"
            s += "Allow: INVITE, ACK, BYE, CANCEL\r\n"
        }
        s += "User-Agent: SIPClient-macOS/0.1.0\r\n"
        if let sdp {
            s += "Content-Type: application/sdp\r\n"
            s += "Content-Length: \(sdp.utf8.count)\r\n"
            s += "\r\n"
            s += sdp
        } else {
            s += "Content-Length: 0\r\n"
            s += "\r\n"
        }
        return s
    }

    /// Echo Via/From/To/Call-ID/CSeq from the inbound request so the
    /// peer matches our 200 OK to its own request.
    private func buildResponseEcho(req: SIPRequest, code: Int, reason: String) -> String {
        let via = req.firstHeader("via") ?? ""
        let from = req.firstHeader("from") ?? ""
        let to = req.firstHeader("to") ?? ""
        let callid = req.firstHeader("call-id") ?? callID
        let cseq = req.firstHeader("cseq") ?? "1 BYE"
        var s = ""
        s += "SIP/2.0 \(code) \(reason)\r\n"
        s += "Via: \(via)\r\n"
        s += "From: \(from)\r\n"
        s += "To: \(to)\r\n"
        s += "Call-ID: \(callid)\r\n"
        s += "CSeq: \(cseq)\r\n"
        s += "Content-Length: 0\r\n"
        s += "\r\n"
        return s
    }

    private func buildBYE() -> String {
        let branch = SIPTokens.branch()
        // Roles flip on BYE: we are now From (with our toTag) and the
        // peer is To (with their fromTag).
        let inviteCSeq = invite.firstHeader("cseq") ?? "1 INVITE"
        let baseSeq = Int(inviteCSeq.split(separator: " ").first ?? "1") ?? 1
        localCSeq = baseSeq + 1

        // Strip the existing tag (if any) from the To header before
        // pinning our own.
        var toAsFrom = toHeader
        if SIPHeaders.tagParam(toAsFrom) == nil {
            toAsFrom += ";tag=\(toTag)"
        }

        var s = ""
        s += "BYE \(fromURI) SIP/2.0\r\n"
        s += "Via: SIP/2.0/UDP \(publicSIPHost):\(publicSIPPort);branch=\(branch);rport\r\n"
        s += "Max-Forwards: 70\r\n"
        s += "From: \(toAsFrom)\r\n"
        s += "To: \(fromHeader)\r\n"
        s += "Call-ID: \(callID)\r\n"
        s += "CSeq: \(localCSeq) BYE\r\n"
        s += "User-Agent: SIPClient-macOS/0.1.0\r\n"
        s += "Content-Length: 0\r\n"
        s += "\r\n"
        return s
    }

    private func buildAnswerSDP(rtpHost: String, rtpPort: UInt16,
                                codec: CodecKind, codecPT: UInt8,
                                dtmfPT: UInt8?, ptime: Int) -> String {
        var s = ""
        s += "v=0\r\n"
        s += "o=sip-client 0 0 IN IP4 \(rtpHost)\r\n"
        s += "s=SIP Client\r\n"
        s += "c=IN IP4 \(rtpHost)\r\n"
        s += "t=0 0\r\n"
        var pts = "\(codecPT)"
        if let dtmfPT { pts += " \(dtmfPT)" }
        s += "m=audio \(rtpPort) RTP/AVP \(pts)\r\n"
        s += "a=rtpmap:\(codecPT) \(codec.rtpmapLine)\r\n"
        if let dtmfPT {
            s += "a=rtpmap:\(dtmfPT) telephone-event/8000\r\n"
            s += "a=fmtp:\(dtmfPT) 0-16\r\n"
        }
        s += "a=ptime:\(ptime)\r\n"
        s += "a=sendrecv\r\n"
        return s
    }

    // MARK: - Wire log

    private func recordSent(method: String, raw: String) {
        onWireLog?(.init(direction: .sent, kind: .sip,
                         summary: "→ \(method)",
                         detail: raw))
    }

    private func recordReceived(_ req: SIPRequest) {
        onWireLog?(.init(direction: .received, kind: .sip,
                         summary: "← \(req.method)",
                         detail: req.raw))
    }
}
