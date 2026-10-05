import AudioToolbox
import Foundation

/// Opus over RTP (RFC 7587), encoded and decoded with AudioToolbox's
/// system codec (`kAudioFormatOpus`). Unlike AMR-WB, macOS ships both
/// directions, so no third-party code is involved.
///
/// We run Opus mono at 48 kHz with 20 ms packets. RFC 7587 fixes the
/// RTP clock at 48 kHz and the rtpmap channel count at 2 regardless of
/// what is actually sent, so neither is negotiable.
enum Opus {
    /// RTP clock and the PCM rate we feed the encoder.
    static let sampleRate: Double = 48000
    /// PCM samples in one 20 ms frame at 48 kHz.
    static let samplesPerFrame = 960
    /// Largest packet duration Opus allows (120 ms at 48 kHz) — the most
    /// one received packet can decode to.
    static let maxSamplesPerPacket = 5760

    /// Samples (at 48 kHz) a packet decodes to, read from its TOC byte
    /// (RFC 6716 §3.1). Lets the decoder hand back exactly as many
    /// samples as the packet covers, independent of decoder priming —
    /// the same timestamp-locked contract `AMRWBDecoder` keeps.
    static func samplesInPacket(_ payload: Data) -> Int? {
        guard let toc = payload.first else { return nil }
        let config = Int(toc >> 3)
        // Per-frame duration in units of 2.5 ms (120 samples).
        let units: Int
        switch config {
        case 0...11:  units = [4, 8, 16, 24][config % 4]   // SILK 10/20/40/60
        case 12...15: units = [4, 8][config % 2]            // Hybrid 10/20
        default:      units = [1, 2, 4, 8][config % 4]      // CELT 2.5/5/10/20
        }
        let frames: Int
        switch toc & 0x03 {
        case 0:       frames = 1
        case 1, 2:    frames = 2
        default:
            guard payload.count >= 2 else { return nil }
            frames = Int(payload[payload.startIndex + 1] & 0x3F)
        }
        let samples = units * 120 * frames
        guard samples > 0, samples <= maxSamplesPerPacket else { return nil }
        return samples
    }

    static func pcmFormat() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                        | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    }

    /// `framesPerPacket` 0 means "varies" — the decoder needs that so it
    /// accepts whatever packet duration the peer chooses to send.
    static func opusFormat(framesPerPacket: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
    }

    /// Returned by input callbacks once their one pending packet has been
    /// handed over. See `AMRWBDecoder.noMoreInput` — `noErr` with zero
    /// packets would latch the converter at end-of-stream.
    static let noMoreInput: OSStatus = -13579
}

/// Target encoder bitrates offered in the dialer. Opus is happy anywhere
/// from 6 to 510 kbit/s; these cover narrowband-ish speech through to
/// what WebRTC uses for music.
enum OpusBitrate: Int, Codable, CaseIterable, Identifiable, Hashable {
    case k16 = 16000, k24 = 24000, k32 = 32000, k48 = 48000, k64 = 64000

    var id: Int { rawValue }
    var displayName: String { "\(rawValue / 1000) kbit/s" }
}

// MARK: - Encoder

/// One 960-sample PCM frame in, one Opus packet out. Opus is stateful,
/// so a single converter lives for the whole call.
final class OpusEncoder: CodecEncoder {
    private var converter: AudioConverterRef?
    private let lock = NSLock()
    private let inBuf = UnsafeMutableRawPointer.allocate(
        byteCount: Opus.samplesPerFrame * 2, alignment: 16)
    private var hasPending = false
    /// Comfortably above `kAudioConverterPropertyMaximumOutputPacketSize`
    /// (750 bytes on current macOS) and under any sane MTU.
    private var scratch = [UInt8](repeating: 0, count: 1500)

    init(bitrate: OpusBitrate) {
        var src = Opus.pcmFormat()
        var dst = Opus.opusFormat(framesPerPacket: UInt32(Opus.samplesPerFrame))
        var conv: AudioConverterRef?
        guard AudioConverterNew(&src, &dst, &conv) == noErr, let conv else { return }
        var br = UInt32(bitrate.rawValue)
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size), &br)
        converter = conv
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        inBuf.deallocate()
    }

    func encode(pcm: [Int16]) -> Data {
        guard let converter else { return Data() }
        lock.lock(); defer { lock.unlock() }

        var input = pcm
        if input.count != Opus.samplesPerFrame {
            input = Array(input.prefix(Opus.samplesPerFrame))
            input.append(contentsOf: [Int16](repeating: 0,
                count: Opus.samplesPerFrame - input.count))
        }
        input.withUnsafeBytes { _ = memcpy(inBuf, $0.baseAddress!, $0.count) }
        hasPending = true

        var packets: UInt32 = 1
        var desc = AudioStreamPacketDescription()
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(scratch.count), mData: nil))
        _ = scratch.withUnsafeMutableBytes { raw in
            abl.mBuffers.mData = raw.baseAddress
            return AudioConverterFillComplexBuffer(
                converter, OpusEncoder.inputProc,
                Unmanaged.passUnretained(self).toOpaque(),
                &packets, &abl, &desc)
        }
        guard packets > 0, desc.mDataByteSize > 0 else { return Data() }
        return Data(scratch[0..<Int(desc.mDataByteSize)])
    }

    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, _, userData in
        let me = Unmanaged<OpusEncoder>.fromOpaque(userData!).takeUnretainedValue()
        guard me.hasPending else {
            ioNumberDataPackets.pointee = 0
            return Opus.noMoreInput
        }
        me.hasPending = false
        // For linear PCM a "packet" is one sample frame.
        ioNumberDataPackets.pointee = UInt32(Opus.samplesPerFrame)
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = 1
        ioData.pointee.mBuffers.mData = me.inBuf
        ioData.pointee.mBuffers.mDataByteSize = UInt32(Opus.samplesPerFrame * 2)
        return noErr
    }
}

// MARK: - Decoder

/// Decodes one RTP payload (any Opus packet duration, mono or stereo —
/// stereo is downmixed by the decoder) to 48 kHz mono PCM.
///
/// The converter swallows a 120-sample pre-skip on the first packet, so
/// output goes through a FIFO and each call returns exactly the number
/// of samples the packet's TOC says it covers.
final class OpusDecoder: CodecDecoder {
    private var converter: AudioConverterRef?
    private let lock = NSLock()
    private let inBuf = UnsafeMutableRawPointer.allocate(byteCount: 1500,
                                                         alignment: 16)
    private var inBytes = 0
    private var packetDesc = AudioStreamPacketDescription()
    private var hasPending = false
    private var fifo: [Int16] = []

    init() {
        var src = Opus.opusFormat(framesPerPacket: 0)
        var dst = Opus.pcmFormat()
        var conv: AudioConverterRef?
        if AudioConverterNew(&src, &dst, &conv) == noErr {
            converter = conv
        }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        inBuf.deallocate()
    }

    func decode(payload: Data) -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        guard payload.count <= 1500,
              let wanted = Opus.samplesInPacket(payload) else { return [] }
        guard let converter else {
            return [Int16](repeating: 0, count: wanted)
        }

        payload.withUnsafeBytes { _ = memcpy(inBuf, $0.baseAddress!, payload.count) }
        inBytes = payload.count
        packetDesc = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(payload.count))
        hasPending = true

        var scratch = [Int16](repeating: 0, count: Opus.maxSamplesPerPacket)
        var produced = UInt32(Opus.maxSamplesPerPacket)
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(Opus.maxSamplesPerPacket * 2), mData: nil))
        let status: OSStatus = scratch.withUnsafeMutableBytes { raw in
            abl.mBuffers.mData = raw.baseAddress
            return AudioConverterFillComplexBuffer(
                converter, OpusDecoder.inputProc,
                Unmanaged.passUnretained(self).toOpaque(),
                &produced, &abl, nil)
        }
        if (status == noErr || status == Opus.noMoreInput) && produced > 0 {
            fifo.append(contentsOf: scratch[0..<Int(produced)])
        }

        if fifo.count >= wanted {
            let out = Array(fifo.prefix(wanted))
            fifo.removeFirst(wanted)
            return out
        }
        var out = fifo
        fifo.removeAll(keepingCapacity: true)
        out.append(contentsOf: [Int16](repeating: 0, count: wanted - out.count))
        return out
    }

    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, outPacketDesc, userData in
        let me = Unmanaged<OpusDecoder>.fromOpaque(userData!).takeUnretainedValue()
        guard me.hasPending else {
            ioNumberDataPackets.pointee = 0
            return Opus.noMoreInput
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
