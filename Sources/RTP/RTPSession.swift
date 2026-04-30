import Foundation

/// Minimal RTP sender + receiver, codec-driven.
///
/// Send side: a background task pulls one codec-frame of PCM from
/// `micBuffer`, encodes via the configured codec, and sends. When the
/// buffer is empty we still encode a silent frame so the codec's
/// adaptive state stays consistent (matters for G.722) and the peer's
/// media path stays open.
///
/// Receive side: a background task drains incoming RTP, parses the header,
/// decodes via the configured codec, and forwards via `onPlaybackPCM`.
///
/// DTMF (RFC 4733): `sendDTMFDigits` flips `dtmfMode` so the audio sender
/// pauses, then emits 4-byte event packets at the negotiated DTMF PT.
final class RTPSession: @unchecked Sendable {
    let socket: UDPSocket
    let remoteHost: String
    let remotePort: UInt16
    var payloadType: UInt8
    let codec: CodecKind
    /// Negotiated packet time in milliseconds (from a=ptime in the SDP
    /// answer, or 20 ms per RFC 3551 default).
    let ptime: Int
    /// DTMF (telephone-event) payload type from the SDP answer, if any.
    var dtmfPT: UInt8?

    let ssrc: UInt32

    private let seqLock = NSLock()
    private var _seq: UInt16
    private var _timestamp: UInt32
    private var _dtmfMode: Bool = false

    /// Producer for outgoing audio. Empty → silence is sent.
    var micBuffer: FrameBuffer?

    /// Called from the receive task with decoded Int16 mono PCM at the
    /// codec's native sample rate (8 kHz for G.711, 16 kHz for G.722).
    var onPlaybackPCM: (@Sendable ([Int16]) -> Void)?

    /// Called when an incoming RTP packet has the DTMF payload type.
    var onTelephoneEvent: (@Sendable (UInt8, UInt16) -> Void)?

    private(set) var packetsSent: UInt64 = 0
    private(set) var packetsReceived: UInt64 = 0
    /// Number of distinct packets we *should* have seen by now, derived
    /// from the inbound sequence number range (RFC 3550 §A.3 algorithm).
    /// `expected - received` is loss; can be negative if the peer
    /// retransmits (duplicates).
    private(set) var packetsExpected: UInt64 = 0
    private(set) var packetsLost: Int64 = 0

    /// First sequence number observed (16-bit, no wrap accounting).
    private var firstSeq: UInt16?
    /// Highest extended sequence number observed (32-bit: ROC<<16 | seq).
    private var maxExtSeq: UInt32 = 0

    private var sendTask: Task<Void, Never>?
    private var recvTask: Task<Void, Never>?

    private let encoder: CodecEncoder
    private let decoder: CodecDecoder

    /// Outbound SRTP context (built from our SDP-offered crypto). Nil
    /// when negotiated profile is plain RTP/AVP.
    private let outboundSRTP: SRTPContext?
    /// Inbound SRTP context (built from peer's SDP-answered crypto).
    /// Lazily learns peer's SSRC from the first received packet.
    private let inboundSRTP: SRTPContext?

    init(socket: UDPSocket,
         remoteHost: String,
         remotePort: UInt16,
         payloadType: UInt8,
         codec: CodecKind,
         ptime: Int = 20,
         outboundCrypto: SDPCryptoLine? = nil,
         inboundCrypto: SDPCryptoLine? = nil) {
        self.socket = socket
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.payloadType = payloadType
        self.codec = codec
        self.ptime = ptime
        self.encoder = codec.makeEncoder()
        self.decoder = codec.makeDecoder()
        let randSSRC = UInt32.random(in: 1...UInt32.max)
        self.ssrc = randSSRC
        self._seq = UInt16.random(in: 0...UInt16.max)
        self._timestamp = UInt32.random(in: 0...UInt32.max)
        self.outboundSRTP = outboundCrypto.map {
            SRTPContext(masterKey: $0.masterKey, masterSalt: $0.masterSalt, ssrc: randSSRC)
        }
        self.inboundSRTP = inboundCrypto.map {
            // Peer SSRC unknown until first packet — set at receive.
            SRTPContext(masterKey: $0.masterKey, masterSalt: $0.masterSalt, ssrc: 0)
        }
    }

    // MARK: - Public send API

    /// Send a single 20 ms encoded audio frame.
    func sendFrame(_ payload: Data) throws {
        try sendPacket(payloadType: payloadType, payload: payload, marker: false,
                       timestampAdvance: codec.timestampAdvance)
    }

    /// Start the audio send loop. Pulls codec-sized PCM frames from
    /// `micBuffer`, encodes, and sends. Halts naturally when `stop()`.
    func startSending() {
        let frameSize = codec.samplesPerFrame
        sendTask = Task.detached(priority: .userInitiated) { [weak self] in
            let interval: UInt64 = 20_000_000
            var nextDeadline = DispatchTime.now().uptimeNanoseconds
            let silentPCM = [Int16](repeating: 0, count: frameSize)
            while !Task.isCancelled {
                guard let self else { return }
                if self.dtmfModeIsActive() {
                    try? await Task.sleep(nanoseconds: interval)
                    continue
                }
                let pcm = self.micBuffer?.readFrame(size: frameSize) ?? silentPCM
                let frame = self.encoder.encode(pcm: pcm)
                do {
                    try self.sendFrame(frame)
                } catch {
                    return
                }
                nextDeadline &+= interval
                let now = DispatchTime.now().uptimeNanoseconds
                if nextDeadline > now {
                    try? await Task.sleep(nanoseconds: nextDeadline - now)
                } else {
                    nextDeadline = now
                    await Task.yield()
                }
            }
        }
    }

    /// Start the receive loop.
    func startReceiving() {
        recvTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pkt: (data: Data, host: String, port: UInt16)?
                do {
                    pkt = try self.socket.recvOnce(timeout: 0.5)
                } catch {
                    return
                }
                guard let pkt, pkt.data.count >= 12 else { continue }
                self.handleRTPPacket(pkt.data)
            }
        }
    }

    /// Send a digit string as RFC 4733 telephone-event packets. Pauses the
    /// audio sender for the duration so audio + DTMF don't interleave. Uses
    /// 6 packets per digit (with the final 3 carrying the End flag) and a
    /// 50 ms gap between digits.
    func sendDTMFDigits(_ digits: String) async {
        guard let dtmfPT else { return }
        setDTMFMode(true)
        defer { setDTMFMode(false) }
        // Let the audio sender notice and stop emitting frames.
        try? await Task.sleep(nanoseconds: 25_000_000)

        let frameSamples: UInt32 = 160       // 20 ms at 8 kHz
        let packetsPerEvent = 6

        for ch in digits {
            guard let event = Self.dtmfEvent(for: ch) else { continue }

            let baseTS = currentTimestamp()

            for i in 0..<packetsPerEvent {
                let isEnd = i >= packetsPerEvent - 3
                let durationSamples = UInt32(min(Int(frameSamples) * (i + 1), Int(UInt16.max)))
                var payload = Data(count: 4)
                payload[0] = event
                payload[1] = (isEnd ? 0x80 : 0) | 0x0A   // E flag + volume 10 dBm0
                payload[2] = UInt8((durationSamples >> 8) & 0xFF)
                payload[3] = UInt8(durationSamples & 0xFF)
                try? sendPacketAtTimestamp(
                    payloadType: dtmfPT,
                    payload: payload,
                    marker: i == 0,
                    timestamp: baseTS
                )
                try? await Task.sleep(nanoseconds: 20_000_000)
            }

            // Advance the audio timestamp past the event so it stays consistent.
            setTimestamp(baseTS &+ frameSamples * UInt32(packetsPerEvent))

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func setDTMFMode(_ active: Bool) {
        seqLock.lock(); defer { seqLock.unlock() }
        _dtmfMode = active
    }

    private func currentTimestamp() -> UInt32 {
        seqLock.lock(); defer { seqLock.unlock() }
        return _timestamp
    }

    private func setTimestamp(_ ts: UInt32) {
        seqLock.lock(); defer { seqLock.unlock() }
        _timestamp = ts
    }

    func stop() {
        sendTask?.cancel(); sendTask = nil
        recvTask?.cancel(); recvTask = nil
    }

    // MARK: - Internal: send paths

    private func sendPacket(payloadType: UInt8, payload: Data, marker: Bool,
                            timestampAdvance: UInt32) throws {
        seqLock.lock()
        let s = _seq
        let t = _timestamp
        _seq &+= 1
        _timestamp &+= timestampAdvance
        seqLock.unlock()
        try writePacket(payloadType: payloadType, payload: payload,
                        marker: marker, seq: s, timestamp: t)
        packetsSent &+= 1
    }

    private func sendPacketAtTimestamp(payloadType: UInt8, payload: Data,
                                       marker: Bool, timestamp: UInt32) throws {
        seqLock.lock()
        let s = _seq
        _seq &+= 1
        seqLock.unlock()
        try writePacket(payloadType: payloadType, payload: payload,
                        marker: marker, seq: s, timestamp: timestamp)
        packetsSent &+= 1
    }

    private func writePacket(payloadType pt: UInt8, payload: Data,
                             marker: Bool, seq: UInt16, timestamp ts: UInt32) throws {
        var pkt = Data(capacity: 12 + payload.count)
        pkt.append(0x80)                             // V=2, P=0, X=0, CC=0
        pkt.append((marker ? 0x80 : 0) | (pt & 0x7F))
        pkt.append(UInt8((seq >> 8) & 0xFF))
        pkt.append(UInt8(seq & 0xFF))
        var tsBE = ts.bigEndian
        withUnsafeBytes(of: &tsBE) { pkt.append(contentsOf: $0) }
        var ssrcBE = ssrc.bigEndian
        withUnsafeBytes(of: &ssrcBE) { pkt.append(contentsOf: $0) }
        pkt.append(payload)
        // Encrypt + authenticate before going on the wire if SRTP is active.
        let onWire: Data
        if let outboundSRTP, let protected = outboundSRTP.protect(pkt) {
            onWire = protected
        } else {
            onWire = pkt
        }
        try socket.send(onWire, to: remoteHost, port: remotePort)
    }

    // MARK: - Internal: receive

    private func dtmfModeIsActive() -> Bool {
        seqLock.lock(); defer { seqLock.unlock() }
        return _dtmfMode
    }

    /// Maintain `packetsExpected` / `packetsLost` from the inbound
    /// sequence numbers, handling 16-bit wrap by tracking a rollover
    /// counter (ROC) baked into a 32-bit "extended" sequence space.
    private func updateLossStats(seq: UInt16) {
        guard let first = firstSeq else {
            firstSeq = seq
            maxExtSeq = UInt32(seq)
            packetsExpected = 1
            packetsLost = 0
            return
        }
        let prevLow = UInt16(maxExtSeq & 0xFFFF)
        let roc = maxExtSeq >> 16
        let extSeq: UInt32
        if seq < prevLow && (UInt32(prevLow) - UInt32(seq)) > 32768 {
            // Forward wrap: new packet from next ROC epoch.
            extSeq = ((roc &+ 1) << 16) | UInt32(seq)
        } else if seq > prevLow && (UInt32(seq) - UInt32(prevLow)) > 32768 && roc > 0 {
            // Late arrival from the previous epoch.
            extSeq = ((roc &- 1) << 16) | UInt32(seq)
        } else {
            extSeq = (roc << 16) | UInt32(seq)
        }
        if extSeq > maxExtSeq { maxExtSeq = extSeq }
        let baseExt = UInt32(first)  // first didn't see any wrap
        packetsExpected = UInt64(maxExtSeq &- baseExt) + 1
        packetsLost = Int64(packetsExpected) - Int64(packetsReceived)
    }

    private func handleRTPPacket(_ data: Data) {
        // Decrypt + verify if inbound SRTP is configured. We learn the
        // peer's SSRC from the first packet; the SDP-negotiated keys
        // bind to that SSRC.
        let rtp: Data
        if let inboundSRTP {
            if inboundSRTP.ssrc == 0, data.count >= 12 {
                let s = (UInt32(data[8]) << 24)
                      | (UInt32(data[9]) << 16)
                      | (UInt32(data[10]) << 8)
                      | UInt32(data[11])
                inboundSRTP.ssrc = s
            }
            guard let plaintext = inboundSRTP.unprotect(data) else { return }
            rtp = plaintext
        } else {
            rtp = data
        }

        let cc = Int(rtp[0] & 0x0F)
        let hasExt = (rtp[0] & 0x10) != 0
        let pt = rtp[1] & 0x7F
        let seq = (UInt16(rtp[2]) << 8) | UInt16(rtp[3])
        let headerLen = 12 + 4 * cc
        var payloadStart = headerLen
        if hasExt && rtp.count >= headerLen + 4 {
            let extLen = Int((UInt16(rtp[headerLen + 2]) << 8) | UInt16(rtp[headerLen + 3]))
            payloadStart = headerLen + 4 + 4 * extLen
        }
        guard rtp.count > payloadStart else { return }
        let payload = rtp.subdata(in: payloadStart..<rtp.count)
        packetsReceived &+= 1
        updateLossStats(seq: seq)

        if let dtmfPT, pt == dtmfPT {
            onTelephoneEvent?(payload.first ?? 0, seq)
            return
        }

        let pcm = decoder.decode(payload: payload)
        onPlaybackPCM?(pcm)
    }

    // MARK: - DTMF helpers

    private static func dtmfEvent(for ch: Character) -> UInt8? {
        switch ch {
        case "0"..."9":
            guard let a = ch.asciiValue, let z = Character("0").asciiValue else { return nil }
            return UInt8(a - z)
        case "*": return 10
        case "#": return 11
        case "A", "a": return 12
        case "B", "b": return 13
        case "C", "c": return 14
        case "D", "d": return 15
        default: return nil
        }
    }
}
