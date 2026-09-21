import Foundation

/// Read/write 16-bit PCM WAV files.
///
/// Clips are canonicalised to 8 kHz mono on import so playback is trivial:
/// read all samples into memory, slice into 160-sample frames, G.711-encode,
/// send. Call recordings use `StreamWriter` instead — stereo, at whatever
/// rate the negotiated codec runs at, written incrementally.
enum WAVFile {
    enum WAVError: Error, LocalizedError {
        case tooShort
        case badRIFF
        case badWAVE
        case missingFmt
        case unsupportedFormat(String)
        case missingData

        var errorDescription: String? {
            switch self {
            case .tooShort: return "WAV file is too short"
            case .badRIFF: return "Not a RIFF file"
            case .badWAVE: return "Not a WAVE file"
            case .missingFmt: return "Missing fmt chunk"
            case .unsupportedFormat(let s): return "Unsupported WAV format: \(s)"
            case .missingData: return "Missing data chunk"
            }
        }
    }

    struct Loaded {
        var sampleRate: UInt32
        var channels: UInt16
        var samples: [Int16]
    }

    /// Read a WAV file. Returns the raw samples plus header info.
    /// Caller is responsible for resampling/channel-mixing if needed.
    static func read(url: URL) throws -> Loaded {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else { throw WAVError.tooShort }
        guard data.subdata(in: 0..<4) == Data("RIFF".utf8) else { throw WAVError.badRIFF }
        guard data.subdata(in: 8..<12) == Data("WAVE".utf8) else { throw WAVError.badWAVE }

        var idx = 12
        var sampleRate: UInt32 = 0
        var channels: UInt16 = 0
        var bitsPerSample: UInt16 = 0
        var audioFormat: UInt16 = 0
        var dataStart = -1
        var dataLen = 0

        while idx + 8 <= data.count {
            let id = data.subdata(in: idx..<(idx + 4))
            let size = data.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(fromByteOffset: idx + 4, as: UInt32.self)
            }
            let chunkBody = idx + 8
            let chunkEnd = chunkBody + Int(size)
            guard chunkEnd <= data.count else { break }

            if id == Data("fmt ".utf8) {
                audioFormat = data.withUnsafeBytes { $0.load(fromByteOffset: chunkBody + 0, as: UInt16.self) }
                channels = data.withUnsafeBytes { $0.load(fromByteOffset: chunkBody + 2, as: UInt16.self) }
                sampleRate = data.withUnsafeBytes { $0.load(fromByteOffset: chunkBody + 4, as: UInt32.self) }
                bitsPerSample = data.withUnsafeBytes { $0.load(fromByteOffset: chunkBody + 14, as: UInt16.self) }
            } else if id == Data("data".utf8) {
                dataStart = chunkBody
                dataLen = Int(size)
            }
            idx = chunkEnd + (Int(size) % 2)  // chunks padded to even byte boundary
        }

        guard sampleRate > 0 else { throw WAVError.missingFmt }
        guard dataStart >= 0 else { throw WAVError.missingData }
        guard audioFormat == 1 else {
            throw WAVError.unsupportedFormat("PCM only (got format code \(audioFormat))")
        }
        guard bitsPerSample == 16 else {
            throw WAVError.unsupportedFormat("16-bit PCM only (got \(bitsPerSample)-bit)")
        }

        let sampleCount = dataLen / 2
        var samples = [Int16](repeating: 0, count: sampleCount)
        _ = samples.withUnsafeMutableBufferPointer { buf in
            data.withUnsafeBytes { raw in
                memcpy(buf.baseAddress, raw.baseAddress!.advanced(by: dataStart), dataLen)
            }
        }
        return Loaded(sampleRate: sampleRate, channels: channels, samples: samples)
    }

    /// Write 16-bit PCM samples to a WAV file. For stereo, `samples` must
    /// already be interleaved (L, R, L, R…).
    static func write(samples: [Int16], to url: URL,
                      sampleRate: UInt32 = 8000, channels: UInt16 = 1) throws {
        var out = header(sampleRate: sampleRate, channels: channels,
                         dataLen: UInt32(samples.count * 2))
        samples.withUnsafeBufferPointer {
            out.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count))
        }
        try out.write(to: url, options: .atomic)
    }

    /// The canonical 44-byte header. `dataLen` may be 0 for a streaming
    /// write, in which case the length fields are patched on close.
    static func header(sampleRate: UInt32, channels: UInt16,
                       dataLen: UInt32) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign: UInt16 = channels * bitsPerSample / 8

        var out = Data()
        out.append("RIFF".data(using: .ascii)!)
        out.append(le32(36 + dataLen))
        out.append("WAVE".data(using: .ascii)!)
        out.append("fmt ".data(using: .ascii)!)
        out.append(le32(16))
        out.append(le16(1))                  // PCM
        out.append(le16(channels))
        out.append(le32(sampleRate))
        out.append(le32(byteRate))
        out.append(le16(blockAlign))
        out.append(le16(bitsPerSample))
        out.append("data".data(using: .ascii)!)
        out.append(le32(dataLen))
        return out
    }

    /// Byte offset of the RIFF chunk length field within `header`.
    private static let riffLenOffset: UInt64 = 4
    /// Byte offset of the data chunk length field within `header`.
    private static let dataLenOffset: UInt64 = 40

    /// Incremental WAV writer: emits a placeholder header, appends PCM as
    /// it arrives, then patches the two length fields on close.
    ///
    /// Call recording needs this rather than `write(samples:to:)` — half
    /// an hour of stereo 16 kHz audio is ~115 MB, which we'd otherwise be
    /// holding in memory for the whole call.
    final class StreamWriter {
        private let handle: FileHandle
        private var dataBytes: UInt32 = 0
        private var bytesSinceSync: UInt32 = 0
        private var closed = false
        /// Re-stamp the length fields roughly every quarter megabyte —
        /// about 4 s of stereo 16 kHz audio. Without this, force-quitting
        /// mid-call would leave a file whose header still claims zero
        /// length, which most players refuse to open. This bounds the
        /// damage to the last few seconds instead of the whole recording.
        private static let syncEvery: UInt32 = 256 * 1024

        let url: URL

        init(url: URL, sampleRate: UInt32, channels: UInt16) throws {
            self.url = url
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw WAVError.missingData
            }
            handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: WAVFile.header(sampleRate: sampleRate,
                                                        channels: channels,
                                                        dataLen: 0))
        }

        func append(_ samples: [Int16]) throws {
            guard !closed, !samples.isEmpty else { return }
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            try handle.write(contentsOf: data)
            dataBytes &+= UInt32(data.count)
            bytesSinceSync &+= UInt32(data.count)
            if bytesSinceSync >= Self.syncEvery {
                try syncLengths()
                bytesSinceSync = 0
            }
        }

        /// Patch the RIFF and data lengths in place, then return the write
        /// cursor to the end so appending can continue.
        private func syncLengths() throws {
            let end = try handle.offset()
            try handle.seek(toOffset: WAVFile.riffLenOffset)
            try handle.write(contentsOf: WAVFile.le32(36 &+ dataBytes))
            try handle.seek(toOffset: WAVFile.dataLenOffset)
            try handle.write(contentsOf: WAVFile.le32(dataBytes))
            try handle.seek(toOffset: end)
        }

        /// Patch the lengths and close. Safe to call twice.
        func close() throws {
            guard !closed else { return }
            closed = true
            try syncLengths()
            try handle.close()
        }
    }

    private static func le16(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }

    private static func le32(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }
}

extension Data {
    fileprivate mutating func append(_ buffer: UnsafeBufferPointer<Int16>) {
        let raw = UnsafeRawBufferPointer(buffer)
        self.append(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: raw.count)
    }
}
