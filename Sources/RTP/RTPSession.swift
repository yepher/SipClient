import Foundation

/// Minimal RTP sender + receiver for 8 kHz, 20 ms G.711 frames (160 samples = 160 bytes).
///
/// Send side: a background task pulls 20 ms PCM frames from `micBuffer`, G.711-
/// encodes them, and sends. Empty buffer → silence so the call stays open.
///
/// Receive side: a background task drains incoming RTP, parses the header,
/// decodes G.711 to Int16 PCM, and forwards via `onPlaybackPCM`.
///
/// DTMF (RFC 4733): `sendDTMFDigits` flips `dtmfMode` so the audio sender
/// pauses, then emits 4-byte event packets at the negotiated DTMF PT.
final class RTPSession: @unchecked Sendable {
    let socket: UDPSocket
    let remoteHost: String
    let remotePort: UInt16
    var payloadType: UInt8
    /// DTMF (telephone-event) payload type from the SDP answer, if any.
    var dtmfPT: UInt8?

    let ssrc: UInt32

    private let seqLock = NSLock()
    private var _seq: UInt16
    private var _timestamp: UInt32
    private var _dtmfMode: Bool = false

    /// Producer for outgoing audio. Empty → silence is sent.
    var micBuffer: FrameBuffer?

    /// Called from the receive task with decoded 8 kHz Int16 mono samples.
    var onPlaybackPCM: (@Sendable ([Int16]) -> Void)?

    /// Called when an incoming RTP packet has the DTMF payload type.
    var onTelephoneEvent: (@Sendable (UInt8, UInt16) -> Void)?

    private(set) var packetsSent: UInt64 = 0
    private(set) var packetsReceived: UInt64 = 0

    private var sendTask: Task<Void, Never>?
    private var recvTask: Task<Void, Never>?

    init(socket: UDPSocket, remoteHost: String, remotePort: UInt16, payloadType: UInt8) {
        self.socket = socket
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.payloadType = payloadType
        self.ssrc = UInt32.random(in: 1...UInt32.max)
        self._seq = UInt16.random(in: 0...UInt16.max)
        self._timestamp = UInt32.random(in: 0...UInt32.max)
    }

    // MARK: - Public send API

    /// Send a single 20 ms G.711 audio frame.
    func sendFrame(_ payload: Data) throws {
        precondition(payload.count == 160, "RTP frame must be 160 bytes for 8 kHz/20 ms G.711")
        try sendPacket(payloadType: payloadType, payload: payload, marker: false,
                       timestampAdvance: 160)
    }

    /// Start the audio send loop. Pulls 160-sample frames from `micBuffer`
    /// or sends silence. Halts naturally when `stop()` is called.
    func startSending() {
        let silenceByte = G711.silenceByte(payloadType: payloadType)
        let silence = Data(repeating: silenceByte, count: 160)
        sendTask = Task.detached(priority: .userInitiated) { [weak self] in
            let interval: UInt64 = 20_000_000
            var nextDeadline = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                guard let self else { return }
                if self.dtmfModeIsActive() {
                    try? await Task.sleep(nanoseconds: interval)
                    continue
                }
                let frame: Data
                if let pcm = self.micBuffer?.readFrame() {
                    frame = self.encode(pcm: pcm)
                } else {
                    frame = silence
                }
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
        seqLock.lock(); _dtmfMode = true; seqLock.unlock()
        defer {
            seqLock.lock(); _dtmfMode = false; seqLock.unlock()
        }
        // Let the audio sender notice and stop emitting frames.
        try? await Task.sleep(nanoseconds: 25_000_000)

        let frameSamples: UInt32 = 160       // 20 ms at 8 kHz
        let packetsPerEvent = 6

        for ch in digits {
            guard let event = Self.dtmfEvent(for: ch) else { continue }

            seqLock.lock()
            let baseTS = _timestamp
            seqLock.unlock()

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
            seqLock.lock()
            _timestamp = baseTS &+ frameSamples * UInt32(packetsPerEvent)
            seqLock.unlock()

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
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
        try socket.send(pkt, to: remoteHost, port: remotePort)
    }

    // MARK: - Internal: encoding & receive

    private func encode(pcm: [Int16]) -> Data {
        var out = Data(count: 160)
        for i in 0..<160 {
            out[i] = (payloadType == 8)
                ? G711.linearToALaw(pcm[i])
                : G711.linearToMuLaw(pcm[i])
        }
        return out
    }

    private func dtmfModeIsActive() -> Bool {
        seqLock.lock(); defer { seqLock.unlock() }
        return _dtmfMode
    }

    private func handleRTPPacket(_ data: Data) {
        let cc = Int(data[0] & 0x0F)
        let hasExt = (data[0] & 0x10) != 0
        let pt = data[1] & 0x7F
        let seq = (UInt16(data[2]) << 8) | UInt16(data[3])
        let headerLen = 12 + 4 * cc
        var payloadStart = headerLen
        if hasExt && data.count >= headerLen + 4 {
            let extLen = Int((UInt16(data[headerLen + 2]) << 8) | UInt16(data[headerLen + 3]))
            payloadStart = headerLen + 4 + 4 * extLen
        }
        guard data.count > payloadStart else { return }
        let payload = data.subdata(in: payloadStart..<data.count)
        packetsReceived &+= 1

        if let dtmfPT, pt == dtmfPT {
            onTelephoneEvent?(payload.first ?? 0, seq)
            return
        }

        var pcm = [Int16](repeating: 0, count: payload.count)
        for i in 0..<payload.count {
            pcm[i] = (pt == 8)
                ? G711.aLawToLinear(payload[i])
                : G711.muLawToLinear(payload[i])
        }
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
