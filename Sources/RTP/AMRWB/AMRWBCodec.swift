import AudioToolbox
import Foundation

// MARK: - Modes

/// AMR-WB bitrate modes (3GPP TS 26.171). The raw value is the frame type
/// (FT) written into the payload table-of-contents byte.
enum AMRWBMode: Int, Codable, CaseIterable, Identifiable, Hashable {
    case k660 = 0, k885 = 1, k1265 = 2, k1425 = 3, k1585 = 4
    case k1825 = 5, k1985 = 6, k2305 = 7, k2385 = 8

    var id: Int { rawValue }

    var kbps: Double {
        switch self {
        case .k660:  return 6.60
        case .k885:  return 8.85
        case .k1265: return 12.65
        case .k1425: return 14.25
        case .k1585: return 15.85
        case .k1825: return 18.25
        case .k1985: return 19.85
        case .k2305: return 23.05
        case .k2385: return 23.85
        }
    }

    var displayName: String { String(format: "%.2f kbit/s", kbps) }
}

// MARK: - Payload geometry

/// Constants and payload framing for AMR-WB over RTP (RFC 4867).
///
/// Three byte layouts are in play and it's worth naming them up front:
///
///  * **Storage format** (RFC 4867 §5.3) — one ToC octet `0 FT(4) Q 0 0`
///    followed by whole speech octets. This is what `vo-amrwbenc` emits
///    and, conveniently, exactly what AudioToolbox's AMR-WB decoder
///    consumes. It is our internal currency.
///  * **Octet-aligned RTP** (§4.4) — a CMR octet, then one ToC octet per
///    frame `F FT(4) Q P P`, then each frame's speech octets. With a
///    single frame per packet (F = 0) the ToC octet is bit-identical to
///    the storage ToC, so conversion is just adding/removing the CMR.
///  * **Bandwidth-efficient RTP** (§4.3) — the same fields with no
///    padding anywhere: CMR(4), then per frame F(1) FT(4) Q(1), then the
///    speech *bits* back to back, zero-padded only at the very end.
///    Needs real bit shuffling, handled by `BitReader`/`BitWriter`.
enum AMRWB {
    /// PCM samples in one 20 ms frame at 16 kHz.
    static let samplesPerFrame = 320
    /// "No mode request" — we never ask the peer to change rate.
    static let cmrNoRequest: UInt8 = 0x0F
    /// Frame type meaning "no data sent for this frame".
    static let ftNoData = 15
    /// Frame type meaning "speech lost in transit".
    static let ftSpeechLost = 14
    /// Highest frame type carrying bits a decoder can use (9 = SID).
    static let ftMaxDecodable = 9

    /// Speech bits per frame indexed by FT (3GPP TS 26.201 Table 2).
    /// 9 is SID (comfort noise); 10–13 are reserved; 14/15 carry nothing.
    static let bitsForFT: [Int] = [132, 177, 253, 285, 317, 365, 397, 461,
                                   477, 40, 0, 0, 0, 0, 0, 0]

    /// Whole octets a frame of this FT occupies in the storage/octet-
    /// aligned layouts (bits rounded up).
    static func bytesForFT(_ ft: Int) -> Int {
        guard ft >= 0 && ft < bitsForFT.count else { return 0 }
        return (bitsForFT[ft] + 7) / 8
    }

    /// Build a storage-format ToC octet from its fields.
    static func storageToC(ft: Int, q: Bool) -> UInt8 {
        (UInt8(ft & 0x0F) << 3) | (q ? 0x04 : 0)
    }

    // MARK: Packing (storage -> RTP)

    /// Wrap one storage-format frame as an octet-aligned RTP payload.
    /// The storage ToC already has F = 0 in bit 7, which is what we want
    /// for the single-frame-per-packet case, so it passes through as-is.
    static func packOctetAligned(storageFrame f: [UInt8]) -> Data {
        guard !f.isEmpty else { return Data() }
        var d = Data(capacity: f.count + 1)
        d.append(cmrNoRequest << 4)   // CMR(4) + R(4) = 0
        d.append(contentsOf: f)
        return d
    }

    /// Wrap one storage-format frame as a bandwidth-efficient payload.
    static func packBandwidthEfficient(storageFrame f: [UInt8]) -> Data {
        guard let toc = f.first else { return Data() }
        let ft = Int((toc >> 3) & 0x0F)
        let q = (toc >> 2) & 0x01
        var w = BitWriter()
        w.write(UInt32(cmrNoRequest), bits: 4)
        w.write(0, bits: 1)                  // F = 0: last frame in packet
        w.write(UInt32(ft), bits: 4)
        w.write(UInt32(q), bits: 1)
        var remaining = ft < bitsForFT.count ? bitsForFT[ft] : 0
        for byte in f.dropFirst() where remaining > 0 {
            let take = min(8, remaining)
            // Speech bits are MSB-first within each storage octet.
            w.write(UInt32(byte >> (8 - take)), bits: take)
            remaining -= take
        }
        return w.finish()
    }

    // MARK: Unpacking (RTP -> storage)

    /// Split an octet-aligned RTP payload into storage-format frames.
    /// Tolerates multi-frame packets (ptime > 20 ms) via the F bit.
    static func unpackOctetAligned(_ payload: Data) -> [[UInt8]] {
        let b = [UInt8](payload)
        guard b.count >= 2 else { return [] }
        var i = 1                       // skip CMR octet
        var tocs: [UInt8] = []
        while i < b.count {
            let t = b[i]; i += 1
            tocs.append(t)
            if (t & 0x80) == 0 { break }   // F = 0 -> last ToC
        }
        var frames: [[UInt8]] = []
        for t in tocs {
            let ft = Int((t >> 3) & 0x0F)
            let n = bytesForFT(ft)
            guard i + n <= b.count else { break }
            var f = [storageToC(ft: ft, q: (t & 0x04) != 0)]
            if n > 0 { f.append(contentsOf: b[i..<(i + n)]) }
            i += n
            frames.append(f)
        }
        return frames
    }

    /// Split a bandwidth-efficient RTP payload into storage-format frames.
    static func unpackBandwidthEfficient(_ payload: Data) -> [[UInt8]] {
        var r = BitReader([UInt8](payload))
        guard r.read(4) != nil else { return [] }   // CMR
        // Read the chained ToC entries first; speech bits follow them all.
        var entries: [(ft: Int, q: Bool)] = []
        while true {
            guard let f = r.read(1), let ft = r.read(4), let q = r.read(1)
            else { return [] }
            entries.append((Int(ft), q == 1))
            if f == 0 { break }
            if entries.count > 12 { break }   // sanity bound
        }
        var frames: [[UInt8]] = []
        for e in entries {
            let bits = e.ft < bitsForFT.count ? bitsForFT[e.ft] : 0
            var f = [storageToC(ft: e.ft, q: e.q)]
            var remaining = bits
            while remaining > 0 {
                let take = min(8, remaining)
                guard let v = r.read(take) else { return frames }
                // Left-align into a whole octet, matching storage layout.
                f.append(UInt8(truncatingIfNeeded: v << (8 - take)))
                remaining -= take
            }
            frames.append(f)
        }
        return frames
    }
}

// MARK: - Bit plumbing

/// MSB-first bit writer used for bandwidth-efficient packing.
private struct BitWriter {
    private var bytes: [UInt8] = []
    private var partial: UInt8 = 0
    private var used = 0            // bits occupied in `partial`

    mutating func write(_ value: UInt32, bits: Int) {
        guard bits > 0 else { return }
        for i in stride(from: bits - 1, through: 0, by: -1) {
            let bit = UInt8((value >> UInt32(i)) & 1)
            partial = (partial << 1) | bit
            used += 1
            if used == 8 { bytes.append(partial); partial = 0; used = 0 }
        }
    }

    /// Flush, zero-padding the final octet as RFC 4867 §4.3 requires.
    mutating func finish() -> Data {
        if used > 0 {
            bytes.append(partial << (8 - used))
            partial = 0; used = 0
        }
        return Data(bytes)
    }
}

/// MSB-first bit reader used for bandwidth-efficient unpacking.
private struct BitReader {
    private let bytes: [UInt8]
    private var pos = 0             // absolute bit offset

    init(_ b: [UInt8]) { bytes = b }

    /// Read `n` bits (n <= 32), or nil if the buffer is exhausted.
    mutating func read(_ n: Int) -> UInt32? {
        guard n > 0, n <= 32, pos + n <= bytes.count * 8 else { return nil }
        var v: UInt32 = 0
        for _ in 0..<n {
            let byte = bytes[pos >> 3]
            let bit = (byte >> (7 - UInt8(pos & 7))) & 1
            v = (v << 1) | UInt32(bit)
            pos += 1
        }
        return v
    }
}

// MARK: - Encoder

/// AMR-WB encoder backed by the vendored `vo-amrwbenc` (see
/// `vendor/VENDORED.md`). macOS has no system AMR-WB encoder, which is
/// why this one native dependency exists.
///
/// The underlying `E_IF_*` state is not reentrant; `RTPSession` drives
/// this from a single send task, but the lock keeps that assumption from
/// becoming a silent corruption bug if that ever changes.
final class AMRWBEncoder: CodecEncoder {
    private let state: UnsafeMutableRawPointer?
    private let mode: Int32
    private let octetAligned: Bool
    private let lock = NSLock()
    /// Generous: the largest real frame is 60 speech octets + ToC.
    private var scratch = [UInt8](repeating: 0, count: 128)

    init(mode: AMRWBMode, octetAligned: Bool) {
        self.state = E_IF_init()
        self.mode = Int32(mode.rawValue)
        self.octetAligned = octetAligned
    }

    deinit { if let state { E_IF_exit(state) } }

    func encode(pcm: [Int16]) -> Data {
        guard let state else { return Data() }
        lock.lock(); defer { lock.unlock() }

        // The encoder demands exactly one 320-sample frame.
        var input = pcm
        if input.count < AMRWB.samplesPerFrame {
            input.append(contentsOf: [Int16](repeating: 0,
                count: AMRWB.samplesPerFrame - input.count))
        } else if input.count > AMRWB.samplesPerFrame {
            input = Array(input.prefix(AMRWB.samplesPerFrame))
        }

        let n: Int32 = input.withUnsafeBufferPointer { sp in
            scratch.withUnsafeMutableBufferPointer { op in
                E_IF_encode(state, mode, sp.baseAddress, op.baseAddress, 0)
            }
        }
        guard n > 1 else { return Data() }
        let storage = Array(scratch[0..<Int(n)])
        return octetAligned
            ? AMRWB.packOctetAligned(storageFrame: storage)
            : AMRWB.packBandwidthEfficient(storageFrame: storage)
    }
}

// MARK: - Decoder

/// AMR-WB decoder built on AudioToolbox's system codec
/// (`kAudioFormatAMR_WB`), which macOS does provide. No third-party code
/// is involved on the receive path.
///
/// AMR-WB is predictive, so one converter must live for the whole call
/// and be fed frames in order — hence the instance state. The converter
/// also primes for a frame or two before producing output, so decoded
/// samples go through a FIFO and each call returns exactly
/// `320 × framesInPacket` samples. That keeps the sample count locked to
/// the RTP timestamp advance, which the jitter buffer relies on.
final class AMRWBDecoder: CodecDecoder {
    private var converter: AudioConverterRef?
    private let octetAligned: Bool
    private let lock = NSLock()

    /// Frame handed to the converter by the input callback. Stable
    /// allocation because the callback yields a pointer Core Audio reads
    /// after the callback returns.
    private let inBuf = UnsafeMutableRawPointer.allocate(byteCount: 256,
                                                         alignment: 16)
    private var inBytes = 0
    private var packetDesc = AudioStreamPacketDescription()
    private var hasPending = false
    private var fifo: [Int16] = []

    /// Returned by the input callback when the current packet has
    /// already been handed over. It must NOT be `noErr` with zero
    /// packets: Core Audio reads that as end-of-stream and latches the
    /// converter shut, after which it silently produces nothing for the
    /// rest of the call. A non-zero status instead means "no more input
    /// right now", which leaves the converter usable for the next packet.
    private static let noMoreInput: OSStatus = -13579

    init(octetAligned: Bool) {
        self.octetAligned = octetAligned
        var src = AudioStreamBasicDescription(
            mSampleRate: 16000, mFormatID: kAudioFormatAMR_WB, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(AMRWB.samplesPerFrame),
            mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0,
            mReserved: 0)
        var dst = AudioStreamBasicDescription(
            mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                        | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var conv: AudioConverterRef?
        if AudioConverterNew(&src, &dst, &conv) == noErr {
            converter = conv
        }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        inBuf.deallocate()
    }

    /// True when the system decoder could not be created — the caller
    /// should treat AMR-WB as unavailable rather than play noise.
    var isAvailable: Bool { converter != nil }

    func decode(payload: Data) -> [Int16] {
        lock.lock(); defer { lock.unlock() }

        let frames = octetAligned
            ? AMRWB.unpackOctetAligned(payload)
            : AMRWB.unpackBandwidthEfficient(payload)
        guard !frames.isEmpty else { return [] }

        let wanted = frames.count * AMRWB.samplesPerFrame
        guard let converter else {
            return [Int16](repeating: 0, count: wanted)
        }

        for f in frames {
            let ft = Int((f[0] >> 3) & 0x0F)
            // SPEECH_LOST / NO_DATA / reserved carry nothing the system
            // decoder will take; substitute silence and keep the clock.
            guard ft <= AMRWB.ftMaxDecodable, f.count > 1 else {
                fifo.append(contentsOf: [Int16](repeating: 0,
                    count: AMRWB.samplesPerFrame))
                continue
            }
            feed(f, into: converter)
        }

        if fifo.count >= wanted {
            let out = Array(fifo.prefix(wanted))
            fifo.removeFirst(wanted)
            return out
        }
        // Still priming: emit what we have, padded, and keep the rest.
        var out = fifo
        fifo.removeAll(keepingCapacity: true)
        out.append(contentsOf: [Int16](repeating: 0, count: wanted - out.count))
        return out
    }

    /// Push one storage-format frame through the converter, appending
    /// whatever PCM it yields to `fifo`.
    private func feed(_ frame: [UInt8], into converter: AudioConverterRef) {
        frame.withUnsafeBytes { _ = memcpy(inBuf, $0.baseAddress!, frame.count) }
        inBytes = frame.count
        packetDesc = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(frame.count))
        hasPending = true

        var scratch = [Int16](repeating: 0, count: AMRWB.samplesPerFrame)
        var produced = UInt32(AMRWB.samplesPerFrame)
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(AMRWB.samplesPerFrame * 2), mData: nil))

        let status: OSStatus = scratch.withUnsafeMutableBytes { raw in
            abl.mBuffers.mData = raw.baseAddress
            return AudioConverterFillComplexBuffer(
                converter, AMRWBDecoder.inputProc,
                Unmanaged.passUnretained(self).toOpaque(),
                &produced, &abl, nil)
        }
        // `noMoreInput` is our own sentinel and entirely expected; any
        // other non-zero status with no output is a real decode failure.
        if status != noErr && status != Self.noMoreInput && produced == 0 { return }
        if produced > 0 { fifo.append(contentsOf: scratch[0..<Int(produced)]) }
    }

    /// Supplies at most one frame per invocation. The converter primes
    /// on the first packet or two (it yields 225 of the first 320 samples
    /// here), which is why the caller buffers output rather than assuming
    /// one packet in gives one frame out.
    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, outPacketDesc, userData in
        let me = Unmanaged<AMRWBDecoder>
            .fromOpaque(userData!).takeUnretainedValue()
        guard me.hasPending else {
            ioNumberDataPackets.pointee = 0
            return AMRWBDecoder.noMoreInput
        }
        me.hasPending = false
        ioNumberDataPackets.pointee = 1
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = 1
        ioData.pointee.mBuffers.mData = me.inBuf
        ioData.pointee.mBuffers.mDataByteSize = UInt32(me.inBytes)
        outPacketDesc?.pointee = withUnsafeMutablePointer(to: &me.packetDesc) { $0 }
        return noErr
    }
}
