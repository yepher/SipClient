import Foundation
import Network

/// Closure that sends a SIP message back to the peer who originated
/// the corresponding request. For UDP that's `sendto(host, port)`; for
/// TCP it's a write to the same NWConnection the request arrived on.
typealias InboundResponder = @Sendable (Data) -> Void

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

    // MARK: - SSH reverse tunnel (inbound SIP signaling, TCP-only)

    @Published var sshHost: String = ""
    @Published var sshUser: String = ""
    @Published var sshPort: UInt16 = 22
    /// Port to bind on the SSH host that forwards back to our local
    /// SIP port. Typically 5060.
    @Published var sshRemoteSIPPort: UInt16 = 5060
    @Published private(set) var sshIsRunning = false
    @Published private(set) var sshLastError: String?

    /// Wire-log surface for the tunnel's stderr / status messages.
    var sshOnLog: (@Sendable (String) -> Void)?

    private var sshProcess: Process?
    private var sshStderrHandle: FileHandle?

    /// Fired on a new INVITE (no Call-ID match against an existing call).
    /// `responder` writes a reply back over the same transport the
    /// request arrived on. Declared `@escaping` so callers can stash it
    /// (e.g. on the `InboundCall` instance) for later replies.
    var onIncomingInvite: (@Sendable (SIPRequest, @escaping InboundResponder) -> Void)?
    /// Fired on any other SIP request (ACK / BYE / CANCEL …).
    var onInDialogRequest: (@Sendable (SIPRequest, @escaping InboundResponder) -> Void)?
    /// Wire-log surfaces.
    var onWireLog: (@Sendable (WireLogEntry) -> Void)?

    private var udpSocket: UDPSocket?
    /// RTP socket pre-allocated at listener start so it can be STUN'd
    /// up front and reused across calls. Single-call concurrency for v1.
    private var rtpSocket: UDPSocket?
    private var udpListenTask: Task<Void, Never>?

    private var tcpListener: NWListener?
    /// Active TCP connections keyed by their object identifier.
    private var tcpConnections: [ObjectIdentifier: NWConnection] = [:]
    private let tcpQueue = DispatchQueue(label: "InboundListener.tcp",
                                         qos: .userInitiated)

    /// Shared RTP socket exposed to InboundCall so the same STUN'd
    /// public address keeps working across calls.
    var sharedRTPSocket: UDPSocket? { rtpSocket }

    func start() throws {
        guard !isListening else { return }
        let udp = try UDPSocket(localPort: localPort)
        udpSocket = udp
        let rtp = try UDPSocket(localPort: localRTPPort)
        rtpSocket = rtp
        detectedLocalIP = (try? UDPSocket.detectLocalIP(
            targetHost: "8.8.8.8", targetPort: 53
        )) ?? "127.0.0.1"

        // TCP listener on the same port. SIP/TCP traffic — including
        // bytes coming in via the SSH reverse tunnel — lands here.
        do {
            let tcp = try NWListener(
                using: .tcp,
                on: NWEndpoint.Port(rawValue: localPort) ?? .any
            )
            tcp.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in
                    self?.acceptTCPConnection(conn)
                }
            }
            tcp.stateUpdateHandler = { [weak self] state in
                if case .failed(let err) = state {
                    Task { @MainActor in
                        self?.lastError = "TCP listener failed: \(err.localizedDescription)"
                    }
                }
            }
            tcp.start(queue: tcpQueue)
            tcpListener = tcp
        } catch {
            // TCP is best-effort — UDP can still work without it.
            onWireLog?(.init(
                direction: .sent, kind: .error,
                summary: "TCP listener failed to bind: \(error.localizedDescription)"
            ))
        }

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
        udpListenTask = Task.detached(priority: .userInitiated) {
            await Self.udpListenLoop(socket: udp,
                                     onInvite: onInvite,
                                     onInDialog: onInDialog,
                                     onLog: onLog)
        }
    }

    func stop() {
        udpListenTask?.cancel()
        udpListenTask = nil
        udpSocket = nil
        rtpSocket = nil
        tcpListener?.cancel()
        tcpListener = nil
        for (_, conn) in tcpConnections { conn.cancel() }
        tcpConnections.removeAll()
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

    // MARK: - SSH tunnel lifecycle

    /// Spawn `/usr/bin/ssh -N -R …` to reverse-forward the configured
    /// SSH host's `sshRemoteSIPPort` back to our local SIP port. Uses
    /// the system OpenSSH client so existing key-agent / `~/.ssh/config`
    /// setups work without us implementing SSH ourselves.
    ///
    /// On success, auto-fills `publicHost` + `publicSIPPort` so inbound
    /// SDP / Contact / Via end up advertising the SSH host.
    func startSSHTunnel() {
        guard !sshIsRunning else { return }
        guard !sshHost.isEmpty, !sshUser.isEmpty else {
            sshLastError = "SSH host and user are required"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N",                          // no remote command, just forward
            "-T",                          // disable pseudo-tty
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", "\(sshPort)",
            "-R", "0.0.0.0:\(sshRemoteSIPPort):localhost:\(localPort)",
            "\(sshUser)@\(sshHost)",
        ]

        let stderr = Pipe()
        process.standardError = stderr
        let stdout = Pipe()
        process.standardOutput = stdout

        let logger = sshOnLog
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { logger?(trimmed) }
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.sshIsRunning = false
                self.sshProcess = nil
                let status = proc.terminationStatus
                if status != 0 {
                    self.sshLastError = "ssh exited (status \(status))"
                    self.sshOnLog?("SSH tunnel exited with status \(status)")
                } else {
                    self.sshLastError = nil
                }
                // Clear auto-populated public fields so the user knows
                // the tunnel address is no longer valid.
                if self.publicHost == self.sshHost { self.publicHost = "" }
                if self.publicSIPPort == self.sshRemoteSIPPort { self.publicSIPPort = 0 }
            }
        }

        do {
            try process.run()
            sshProcess = process
            sshIsRunning = true
            sshLastError = nil
            // Auto-fill public address. The user's manual values, if any,
            // are overwritten — that's the point of clicking Start.
            publicHost = sshHost
            publicSIPPort = sshRemoteSIPPort
            sshOnLog?("SSH tunnel started: \(sshUser)@\(sshHost):\(sshPort) → "
                      + "remote :\(sshRemoteSIPPort) → local :\(localPort)")
        } catch {
            sshLastError = error.localizedDescription
            sshOnLog?("Failed to launch ssh: \(error.localizedDescription)")
        }
    }

    func stopSSHTunnel() {
        guard let p = sshProcess else { return }
        p.terminate()
        // terminationHandler will clean up state and clear public fields.
    }

    /// `nonisolated` is critical: without it the static func inherits
    /// `@MainActor` from the enclosing class, the `await` hops back
    /// onto MainActor, and `recvOnce`'s 0.5 s blocking poll freezes
    /// the UI every iteration.
    nonisolated private static func udpListenLoop(
        socket: UDPSocket,
        onInvite: (@Sendable (SIPRequest, @escaping InboundResponder) -> Void)?,
        onInDialog: (@Sendable (SIPRequest, @escaping InboundResponder) -> Void)?,
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
                    summary: "← \(request.method) from \(r.host):\(r.port) (udp)",
                    detail: request.raw
                ))
                let responder: InboundResponder = { data in
                    try? socket.send(data, to: r.host, port: r.port)
                }
                if request.method == "INVITE" {
                    onInvite?(request, responder)
                } else {
                    onInDialog?(request, responder)
                }
            case .right:
                // We're a UAS for the inbound flow — responses arriving
                // here are for an outgoing BYE we sent (peer ack); just
                // ignore for v1.
                break
            }
        }
    }

    /// Called by the NWListener when a peer opens a TCP connection.
    /// Each connection spawns its own framed-message read loop; replies
    /// for any request received on this connection go back through the
    /// same NWConnection.
    private func acceptTCPConnection(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        tcpConnections[key] = connection

        let onInvite = onIncomingInvite
        let onInDialog = onInDialogRequest
        let onLog = onWireLog

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in
                    self?.tcpConnections.removeValue(forKey: key)
                }
            default:
                break
            }
        }
        connection.start(queue: tcpQueue)

        Self.beginTCPRead(
            connection: connection,
            buffer: Data(),
            onInvite: onInvite,
            onInDialog: onInDialog,
            onLog: onLog
        )
    }

    /// Recursive read loop. Each chunk is appended to `buffer`; whenever
    /// we have enough bytes for a Content-Length-framed SIP message we
    /// dispatch it and recurse on the remainder.
    nonisolated private static func beginTCPRead(
        connection: NWConnection,
        buffer: Data,
        onInvite: (@Sendable (SIPRequest, @escaping InboundResponder) -> Void)?,
        onInDialog: (@Sendable (SIPRequest, @escaping InboundResponder) -> Void)?,
        onLog: (@Sendable (WireLogEntry) -> Void)?
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            data, _, isComplete, error in
            var working = buffer
            if let data, !data.isEmpty { working.append(data) }
            // Drain as many complete framed messages as we have.
            while let msg = StreamSIPTransport.extractFramedMessage(from: working) {
                let consumed = msg.count
                working.removeFirst(consumed)
                guard let either = SIPParser.parseMessage(msg) else { continue }
                switch either {
                case .left(let request):
                    onLog?(.init(
                        direction: .received, kind: .sip,
                        summary: "← \(request.method) (tcp)",
                        detail: request.raw
                    ))
                    let responder: InboundResponder = { reply in
                        connection.send(content: reply,
                                        completion: .contentProcessed { _ in })
                    }
                    if request.method == "INVITE" {
                        onInvite?(request, responder)
                    } else {
                        onInDialog?(request, responder)
                    }
                case .right:
                    break
                }
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            beginTCPRead(connection: connection, buffer: working,
                         onInvite: onInvite, onInDialog: onInDialog,
                         onLog: onLog)
        }
    }
}

/// State machine for a single inbound SIP call (UAS). Sends provisional
/// + final responses, parses the offer SDP, builds the answer SDP, and
/// hands an `RTPSession` to the caller via `onAnswered`.
///
/// Transport-agnostic: the listener provides an `InboundResponder`
/// closure that knows how to write back over the same UDP datagram
/// path or the same TCP connection the request arrived on. The latest
/// responder is kept in a lock-protected slot so in-dialog requests
/// arriving on a different connection (rare on TCP) update where our
/// proactive BYE goes.
final class InboundCall: @unchecked Sendable {
    let invite: SIPRequest
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

    private let responderLock = NSLock()
    private var _responder: InboundResponder

    init(invite: SIPRequest,
         responder: @escaping InboundResponder,
         rtpSocket: UDPSocket,
         publicSIPHost: String, publicSIPPort: UInt16,
         publicRTPHost: String, publicRTPPort: UInt16) {
        self.invite = invite
        self._responder = responder
        self.rtpSocket = rtpSocket
        self.publicSIPHost = publicSIPHost
        self.publicSIPPort = publicSIPPort
        self.publicRTPHost = publicRTPHost
        self.publicRTPPort = publicRTPPort
    }

    private func send(_ data: Data) {
        responderLock.lock()
        let r = _responder
        responderLock.unlock()
        r(data)
    }

    /// Update the responder when a later in-dialog request arrives on
    /// a different transport / connection. We send subsequent replies
    /// (or a proactive BYE) through the most recent path.
    private func updateResponder(_ responder: @escaping InboundResponder) {
        responderLock.lock()
        _responder = responder
        responderLock.unlock()
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
        send(Data(resp.utf8))
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
        send(Data(resp.utf8))

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
        send(Data(resp.utf8))
        ended = true
        onEnded?()
    }

    /// Send BYE to terminate an active call from our side.
    func hangup() throws {
        let bye = buildBYE()
        recordSent(method: "BYE", raw: bye)
        send(Data(bye.utf8))
        ended = true
        rtpSession?.stop()
        onEnded?()
    }

    /// Handle an in-dialog request (ACK / BYE / CANCEL) routed in by
    /// the listener. Returns true if it belonged to this call.
    func handleInDialogRequest(_ req: SIPRequest,
                               responder: @escaping InboundResponder) -> Bool {
        guard req.firstHeader("call-id") == callID else { return false }
        // The peer might have come back on a fresh transport — keep
        // our latest reply path in sync.
        updateResponder(responder)
        switch req.method {
        case "ACK":
            recordReceived(req)
        case "BYE":
            let ok = buildResponseEcho(req: req, code: 200, reason: "OK")
            send(Data(ok.utf8))
            recordSent(method: "200 OK (to BYE)", raw: ok)
            ended = true
            rtpSession?.stop()
            onEnded?()
        case "CANCEL":
            let ok = buildResponseEcho(req: req, code: 200, reason: "OK")
            send(Data(ok.utf8))
            recordSent(method: "200 OK (to CANCEL)", raw: ok)
            if !answered {
                let term = buildResponse(code: 487,
                                         reason: "Request Terminated",
                                         sdp: nil)
                send(Data(term.utf8))
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
