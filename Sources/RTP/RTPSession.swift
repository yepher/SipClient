import Foundation

/// Minimal RTP sender for 8 kHz, 20 ms G.711 frames (160 samples = 160 bytes).
///
/// One RTPSession exists per active call. The owning SIPCall is the only
/// user, so we don't bother with extra concurrency protection.
final class RTPSession: @unchecked Sendable {
    let socket: UDPSocket
    let remoteHost: String
    let remotePort: UInt16
    var payloadType: UInt8

    let ssrc: UInt32
    var seq: UInt16
    var timestamp: UInt32

    private var sendTask: Task<Void, Never>?

    init(socket: UDPSocket, remoteHost: String, remotePort: UInt16, payloadType: UInt8) {
        self.socket = socket
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.payloadType = payloadType
        self.ssrc = UInt32.random(in: 1...UInt32.max)
        self.seq = UInt16.random(in: 0...UInt16.max)
        self.timestamp = UInt32.random(in: 0...UInt32.max)
    }

    /// Send a single 20 ms RTP packet. Payload must be 160 bytes (G.711 8 kHz).
    func sendFrame(_ payload: Data, marker: Bool = false) throws {
        precondition(payload.count == 160, "RTP frame must be 160 bytes for 8 kHz/20 ms G.711")
        var pkt = Data(capacity: 12 + 160)
        pkt.append(0x80)                       // V=2, P=0, X=0, CC=0
        pkt.append((marker ? 0x80 : 0) | (payloadType & 0x7F))
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
    }

    /// Spawn a background task that sends G.711 silence frames every 20 ms.
    /// Keeps the remote SIP/RTP path open while we don't have real audio yet.
    func startSilenceKeepalive() {
        let silence = Data(repeating: G711.silenceByte(payloadType: payloadType), count: 160)
        sendTask = Task.detached(priority: .userInitiated) { [weak self] in
            // 20 ms cadence
            let interval: UInt64 = 20_000_000
            var nextDeadline = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try self.sendFrame(silence)
                } catch {
                    return
                }
                nextDeadline &+= interval
                let now = DispatchTime.now().uptimeNanoseconds
                if nextDeadline > now {
                    try? await Task.sleep(nanoseconds: nextDeadline - now)
                } else {
                    // Behind schedule — yield and continue
                    await Task.yield()
                }
            }
        }
    }

    func stop() {
        sendTask?.cancel()
        sendTask = nil
    }
}
