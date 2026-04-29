import Foundation

/// Per-direction SRTP context (RFC 3711) using the `AES_CM_128_HMAC_SHA1_80`
/// crypto suite — AES-128 in counter mode for encryption, HMAC-SHA1
/// truncated to 80 bits for authentication.
///
/// `protect()` consumes a plain RTP packet and returns the SRTP packet
/// (encrypted payload + 10-byte auth tag appended). `unprotect()` is
/// the inverse: verify the tag, decrypt the payload, return the RTP
/// packet — or `nil` if authentication fails.
///
/// One context per direction. The outbound context uses our SSRC and
/// our master key (advertised in our SDP offer). The inbound context
/// uses the peer's SSRC (learned from the first received packet) and
/// the peer's master key (read from their SDP answer).
///
/// Replay protection is intentionally omitted — this is a developer
/// test client running against trusted servers.
final class SRTPContext: @unchecked Sendable {
    let masterKey: Data    // 16 bytes
    let masterSalt: Data   // 14 bytes
    var ssrc: UInt32       // outbound: ours; inbound: learned

    /// Derived per-session keys (RFC 3711 §4.3, labels 0x00, 0x01, 0x02).
    private let encKey: Data    // 16 bytes
    private let authKey: Data   // 20 bytes
    private let saltKey: Data   // 14 bytes

    private let lock = NSLock()
    private var roc: UInt32 = 0
    private var lastSeq: UInt16 = 0
    private var initialized = false

    init(masterKey: Data, masterSalt: Data, ssrc: UInt32) {
        precondition(masterKey.count == 16, "master key must be 16 bytes")
        precondition(masterSalt.count == 14, "master salt must be 14 bytes")
        self.masterKey = masterKey
        self.masterSalt = masterSalt
        self.ssrc = ssrc
        self.encKey = SRTPCrypto.deriveKey(masterKey: masterKey,
                                           masterSalt: masterSalt,
                                           label: 0x00, outputLength: 16)
        self.authKey = SRTPCrypto.deriveKey(masterKey: masterKey,
                                            masterSalt: masterSalt,
                                            label: 0x01, outputLength: 20)
        self.saltKey = SRTPCrypto.deriveKey(masterKey: masterKey,
                                             masterSalt: masterSalt,
                                             label: 0x02, outputLength: 14)
    }

    /// Encrypt + authenticate an outgoing RTP packet. Returns the SRTP
    /// packet (header || encrypted payload || 10-byte auth tag).
    func protect(_ rtp: Data) -> Data? {
        guard let (headerLen, seq) = parseHeader(rtp) else { return nil }
        let payload = rtp.subdata(in: headerLen..<rtp.count)

        let currentROC: UInt32 = lock.withLock {
            if !initialized {
                initialized = true
            } else if seq < lastSeq && (UInt32(lastSeq) - UInt32(seq)) > 32768 {
                roc &+= 1
            }
            lastSeq = seq
            return roc
        }

        let index: UInt64 = (UInt64(currentROC) << 16) | UInt64(seq)
        let iv = computeIV(ssrc: ssrc, index: index)
        let encrypted = SRTPCrypto.aesCTR(key: encKey, iv: iv, input: payload)

        var packet = rtp.subdata(in: 0..<headerLen)
        packet.append(encrypted)

        // M = packet || ROC (big-endian, RFC 3711 §3.4)
        var macInput = packet
        var rocBE = currentROC.bigEndian
        withUnsafeBytes(of: &rocBE) { macInput.append(contentsOf: $0) }

        let tag = SRTPCrypto.hmacSHA1_80(key: authKey, data: macInput)
        packet.append(tag)
        return packet
    }

    /// Verify + decrypt an incoming SRTP packet. Returns the recovered
    /// RTP packet, or nil if the auth tag doesn't match.
    func unprotect(_ srtp: Data) -> Data? {
        guard srtp.count >= 12 + 10 else { return nil }
        guard let (headerLen, seq) = parseHeader(srtp) else { return nil }

        let payloadEnd = srtp.count - 10
        guard payloadEnd >= headerLen else { return nil }
        let receivedTag = srtp.subdata(in: payloadEnd..<srtp.count)
        let body = srtp.subdata(in: 0..<payloadEnd)  // header + encrypted payload

        // Estimate ROC for this packet given out-of-order arrival.
        let estimatedROC: UInt32 = lock.withLock {
            estimateROC(seq: seq)
        }

        var macInput = body
        var rocBE = estimatedROC.bigEndian
        withUnsafeBytes(of: &rocBE) { macInput.append(contentsOf: $0) }
        let expectedTag = SRTPCrypto.hmacSHA1_80(key: authKey, data: macInput)
        guard constantTimeEqual(expectedTag, receivedTag) else { return nil }

        // Tag verified — promote the estimated ROC and update lastSeq.
        lock.withLock {
            if !initialized {
                roc = estimatedROC
                lastSeq = seq
                initialized = true
            } else if estimatedROC > roc
                || (estimatedROC == roc && seq > lastSeq) {
                roc = estimatedROC
                lastSeq = seq
            }
        }

        let index: UInt64 = (UInt64(estimatedROC) << 16) | UInt64(seq)
        let iv = computeIV(ssrc: ssrc, index: index)
        let encrypted = body.subdata(in: headerLen..<body.count)
        let plaintext = SRTPCrypto.aesCTR(key: encKey, iv: iv, input: encrypted)

        var rtp = body.subdata(in: 0..<headerLen)
        rtp.append(plaintext)
        return rtp
    }

    /// Estimate the ROC for an incoming SEQ given current `roc` and
    /// `lastSeq`. Per RFC 3711 §3.3.1 — pick the ROC value that puts
    /// the packet's index closest to the last-seen index.
    private func estimateROC(seq: UInt16) -> UInt32 {
        guard initialized else { return roc }
        if lastSeq < 32768 {
            if Int(seq) - Int(lastSeq) > 32768 {
                return roc &- 1   // late packet from previous epoch
            }
        } else {
            if Int(lastSeq) - Int(seq) > 32768 {
                return roc &+ 1   // wrapped into next epoch
            }
        }
        return roc
    }

    /// Build the per-packet 128-bit IV per RFC 3711 §4.1.1:
    ///     IV = (k_s * 2^16) XOR (SSRC * 2^64) XOR (i * 2^16)
    /// where k_s is the 14-byte session salt, SSRC is 32-bit, and
    /// i is the 48-bit packet index (ROC || SEQ).
    private func computeIV(ssrc: UInt32, index: UInt64) -> Data {
        var iv = Data(count: 16)
        // bytes 0..13 ← session salt; bytes 14..15 stay 0
        iv.replaceSubrange(0..<14, with: saltKey)
        // XOR SSRC into bytes 4..7 (big-endian)
        iv[4] ^= UInt8((ssrc >> 24) & 0xFF)
        iv[5] ^= UInt8((ssrc >> 16) & 0xFF)
        iv[6] ^= UInt8((ssrc >> 8)  & 0xFF)
        iv[7] ^= UInt8( ssrc        & 0xFF)
        // XOR index into bytes 8..13 (48-bit big-endian)
        iv[8]  ^= UInt8((index >> 40) & 0xFF)
        iv[9]  ^= UInt8((index >> 32) & 0xFF)
        iv[10] ^= UInt8((index >> 24) & 0xFF)
        iv[11] ^= UInt8((index >> 16) & 0xFF)
        iv[12] ^= UInt8((index >> 8)  & 0xFF)
        iv[13] ^= UInt8( index        & 0xFF)
        return iv
    }

    /// Parse the RTP fixed-header to find where the payload starts and
    /// the sequence number. Returns (headerLength, seq) or nil if the
    /// packet is too short / malformed.
    private func parseHeader(_ rtp: Data) -> (Int, UInt16)? {
        guard rtp.count >= 12 else { return nil }
        let cc = Int(rtp[0] & 0x0F)
        let hasExt = (rtp[0] & 0x10) != 0
        let seq = (UInt16(rtp[2]) << 8) | UInt16(rtp[3])
        var headerLen = 12 + 4 * cc
        if hasExt {
            guard rtp.count >= headerLen + 4 else { return nil }
            let extLen = Int(
                (UInt16(rtp[headerLen + 2]) << 8) | UInt16(rtp[headerLen + 3])
            )
            headerLen += 4 + 4 * extLen
        }
        guard rtp.count >= headerLen else { return nil }
        return (headerLen, seq)
    }
}

private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
