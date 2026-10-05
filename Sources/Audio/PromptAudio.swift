import AVFoundation
import Foundation

/// Produces audio to inject into a call — library clips and synthesized
/// speech — as mono Int16 at whatever rate the negotiated codec encodes.
///
/// Clips are stored at 8 kHz, and before this existed they were written
/// into the call unconverted, so on G.722 / AMR-WB / Opus they played two
/// to six times too fast.
enum PromptAudio {
    /// Resample mono Int16 PCM. Identity when the rates already match.
    static func resample(_ samples: [Int16], from inRate: Double, to outRate: Double) -> [Int16] {
        guard inRate != outRate, !samples.isEmpty,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: inRate,
                                      channels: 1, interleaved: true),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(samples.count))
        else { return samples }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buf.int16ChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        return convert(buf, to: outRate) ?? samples
    }

    /// Convert any PCM buffer (first channel only) to mono Int16 at `outRate`.
    static func convert(_ input: AVAudioPCMBuffer, to outRate: Double) -> [Int16]? {
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: outRate,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input.format, to: outFmt)
        else { return nil }
        let ratio = outRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: capacity)
        else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let data = out.int16ChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    /// Render `text` with the system voice, offline (nothing plays on the
    /// local speaker). Returns nil if synthesis fails or times out.
    @MainActor
    static func synthesize(_ text: String, sampleRate: Double) async -> [Int16]? {
        let synth = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        let collected: (samples: [Float], rate: Double)? = await withCheckedContinuation { cont in
            let sink = SynthesisSink(cont)
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                sink.append(pcm)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { sink.finish(timedOut: true) }
        }
        // Keep the synthesizer alive until its callbacks are done.
        withExtendedLifetime(synth) {}

        guard let collected, collected.rate > 0,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: collected.rate,
                                      channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(collected.samples.count))
        else { return nil }
        buf.frameLength = AVAudioFrameCount(collected.samples.count)
        collected.samples.withUnsafeBufferPointer {
            buf.floatChannelData![0].update(from: $0.baseAddress!, count: collected.samples.count)
        }
        return convert(buf, to: sampleRate)
    }
}

/// Collects synthesizer output and resumes the waiting task exactly once.
/// The synthesizer's callback and the timeout fire on different threads,
/// hence the lock.
private final class SynthesisSink: @unchecked Sendable {
    typealias Result = (samples: [Float], rate: Double)?
    private let lock = NSLock()
    private var cont: CheckedContinuation<Result, Never>?
    private var samples: [Float] = []
    private var rate: Double = 0

    init(_ cont: CheckedContinuation<Result, Never>) { self.cont = cont }

    func append(_ pcm: AVAudioPCMBuffer) {
        // A zero-length buffer marks the end of the utterance.
        guard pcm.frameLength > 0 else { finish(timedOut: false); return }
        let n = Int(pcm.frameLength)
        lock.lock(); defer { lock.unlock() }
        rate = pcm.format.sampleRate
        if let f = pcm.floatChannelData {
            samples.append(contentsOf: UnsafeBufferPointer(start: f[0], count: n))
        } else if let i = pcm.int16ChannelData {
            samples.append(contentsOf: UnsafeBufferPointer(start: i[0], count: n)
                .map { Float($0) / 32768 })
        }
    }

    func finish(timedOut: Bool) {
        lock.lock()
        let c = cont
        cont = nil
        let result: Result = (timedOut || samples.isEmpty) ? nil : (samples, rate)
        lock.unlock()
        c?.resume(returning: result)
    }
}
