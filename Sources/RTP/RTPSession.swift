import Foundation

/// Minimal RTP sender + receiver for 8 kHz, 20 ms G.711 frames (160 samples = 160 bytes).
///
/// Send side: a background task pulls 20 ms PCM frames from `micBuffer` (if
/// any), G.711-encodes them, and sends. If the buffer is empty it sends
/// silence so the remote keeps the call open.
///
/// Receive side: a background task drains incoming RTP packets, parses the
/// 12-byte header, decodes the G.711 payload to Int16 PCM, and forwards
/// the samples to `onPlaybackPCM`.
final class RTPSession: @unchecked Sendable {
    let socket: UDPSocket
    let remoteHost: String
    let remotePort: UInt16
    var payloadType: UInt8

    let ssrc: UInt32
    var seq: UInt16
    var timestamp: UInt32

    /// Producer for outgoing audio. May be nil → silence.
    var micBuffer: FrameBuffer?

    /// Called from the receive task with decoded 8 kHz Int16 mono samples.
    var onPlaybackPCM: (@Sendable ([Int16]) -> Void)?

    /// Called when an incoming RTP packet has the unexpected payload type
    /// (e.g. telephone-event during normal audio). Best-effort.
    var onTelephoneEvent: (@Sendable (UInt8, UInt16) -> Void)?

    /// Stats updated by the recv task.
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
        self.seq = UInt16.random(in: 0...UInt16.max)
        self.timestamp = UInt32.random(in: 0...UInt32.max)
    }

    /// Send a single 160-byte (20 ms) G.711 frame. Increments seq/ts.
    func sendFrame(_ payload: Data) throws {
        precondition(payload.count == 160, "RTP frame must be 160 bytes for 8 kHz/20 ms G.711")
        var pkt = Data(capacity: 12 + 160)
        pkt.append(0x80)                       // V=2, P=0, X=0, CC=0
        pkt.append(payloadType & 0x7F)         // M=0
        pkt.append(UInt8((seq >> 8) & 0xFF))
        pkt.append(UInt8(seq & 0xFF))
        var tsBE = timestamp.bigEndian
        withUnsafeBytes(of: &tsBE) { pkt.append(contentsOf: $0) }
        var ssrcBE = ssrc.bigEndian
        withUnsafeBytes(of: &ssrcBE) { pkt.append(contentsOf: $0) }
        pkt.append(payload)

        try socket.send(pkt, to: remoteHost, port: remotePort)
        seq &+= 1
        timestamp &+= 160
        packetsSent &+= 1
    }

    /// Start the send loop. Runs until `stop()` is called.
    func startSending() {
        let silenceByte = G711.silenceByte(payloadType: payloadType)
        let silence = Data(repeating: silenceByte, count: 160)
        sendTask = Task.detached(priority: .userInitiated) { [weak self] in
            let interval: UInt64 = 20_000_000
            var nextDeadline = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                guard let self else { return }
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

    /// Start the receive loop. Drains the RTP socket and forwards decoded
    /// audio samples to `onPlaybackPCM`.
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

    func stop() {
        sendTask?.cancel(); sendTask = nil
        recvTask?.cancel(); recvTask = nil
    }

    // MARK: - Internal

    private func encode(pcm: [Int16]) -> Data {
        var out = Data(count: 160)
        for i in 0..<160 {
            out[i] = (payloadType == 8)
                ? G711.linearToALaw(pcm[i])
                : G711.linearToMuLaw(pcm[i])
        }
        return out
    }

    private func handleRTPPacket(_ data: Data) {
        // Parse 12-byte fixed header
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

        // Telephone-event: forward as event for future DTMF UI
        if pt != payloadType, let cb = onTelephoneEvent {
            cb(pt, seq)
            return
        }

        // Decode G.711 → Int16 PCM
        var pcm = [Int16](repeating: 0, count: payload.count)
        for i in 0..<payload.count {
            pcm[i] = (pt == 8)
                ? G711.aLawToLinear(payload[i])
                : G711.muLawToLinear(payload[i])
        }
        onPlaybackPCM?(pcm)
    }
}
