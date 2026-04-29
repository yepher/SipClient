import Foundation

/// Read/write 8 kHz, mono, 16-bit PCM WAV files.
///
/// We canonicalise everything to this format on import so clip playback is
/// trivial: read all samples into memory, slice into 160-sample frames,
/// G.711-encode, send.
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

    /// Write 8 kHz mono 16-bit PCM samples to a WAV file.
    static func write(samples: [Int16], to url: URL,
                      sampleRate: UInt32 = 8000, channels: UInt16 = 1) throws {
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign: UInt16 = channels * bitsPerSample / 8
        let dataLen = UInt32(samples.count * 2)
        let riffLen = 36 + dataLen

        var out = Data()
        out.append("RIFF".data(using: .ascii)!)
        out.append(le32(riffLen))
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
        samples.withUnsafeBufferPointer {
            out.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count))
        }
        try out.write(to: url, options: .atomic)
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
