import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var wireLog: [WireLogEntry] = []
    @Published var callStatus: String = "Idle"
    @Published var callInProgress: Bool = false
    @Published var audioClips: [AudioClip] = []
    @Published var scenarios: [Scenario] = []
    @Published var rtpStats: String = ""

    let audioEngine = AudioEngine()

    /// Shared mic→RTP buffer. The mic tap writes here, the RTP send loop
    /// reads from here. Empty → silence is sent.
    let callMicBuffer = FrameBuffer(maxSeconds: 1.0)

    private var currentCall: SIPCall?
    private var currentTask: Task<Void, Never>?
    private var rtpStatsTask: Task<Void, Never>?

    init() {
        loadAudioLibrary()
    }

    // MARK: - Wire log

    func appendLog(_ entry: WireLogEntry) {
        wireLog.append(entry)
        if wireLog.count > 5_000 {
            wireLog.removeFirst(wireLog.count - 5_000)
        }
    }

    func clearLog() { wireLog.removeAll() }

    // MARK: - Outbound call

    func placeCall(config: SIPCallConfig) {
        guard !callInProgress else { return }
        callInProgress = true
        callStatus = "Starting…"

        let call = SIPCall(config: config)
        currentCall = call

        call.onWireLog = { entry in
            Task { @MainActor in self.appendLog(entry) }
        }
        call.onStatus = { s in
            Task { @MainActor in self.callStatus = s }
        }
        call.onMediaReady = { rtpSession in
            Task { @MainActor in self.attachAudio(to: rtpSession) }
        }
        call.onMediaEnd = {
            Task { @MainActor in self.detachAudio() }
        }

        currentTask = Task.detached(priority: .userInitiated) {
            do {
                try call.run()
                await MainActor.run {
                    self.callStatus = "Ended"
                    self.callInProgress = false
                    self.currentCall = nil
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                await MainActor.run {
                    self.callStatus = "Failed: \(msg)"
                    self.callInProgress = false
                    self.currentCall = nil
                    self.appendLog(.init(direction: .sent, kind: .error,
                                         summary: "Call failed: \(msg)"))
                }
            }
        }
    }

    func hangup() {
        currentCall?.requestHangup()
    }

    // MARK: - Audio wiring during a call

    private func attachAudio(to rtp: RTPSession) {
        rtp.micBuffer = callMicBuffer
        rtp.onPlaybackPCM = { samples in
            Task { @MainActor in
                self.audioEngine.enqueuePlayback(samples: samples)
            }
        }

        Task { @MainActor in
            let ok = await AudioEngine.requestMicAuthorization()
            guard ok else {
                self.appendLog(.init(direction: .sent, kind: .error,
                                     summary: "Microphone access denied"))
                return
            }
            do {
                try self.audioEngine.startCallMode(micBuffer: self.callMicBuffer)
                self.appendLog(.init(direction: .sent, kind: .info,
                                     summary: "Mic → RTP started"))
            } catch {
                self.appendLog(.init(direction: .sent, kind: .error,
                                     summary: "Mic start failed: \(error.localizedDescription)"))
            }
        }

        // Periodic RTP stats publishing
        rtpStatsTask = Task.detached { [weak rtp] in
            while !Task.isCancelled, let r = rtp {
                let s = "RTP sent=\(r.packetsSent) recv=\(r.packetsReceived)"
                await MainActor.run { self.rtpStats = s }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func detachAudio() {
        callMicBuffer.clear()
        audioEngine.stopCallMode()
        rtpStatsTask?.cancel()
        rtpStatsTask = nil
    }

    // MARK: - Audio Library

    /// Where audio clips are persisted on disk.
    var clipsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("SipClient/Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var libraryIndexURL: URL {
        clipsDirectory.appendingPathComponent("library.json")
    }

    func loadAudioLibrary() {
        guard let data = try? Data(contentsOf: libraryIndexURL),
              let clips = try? JSONDecoder().decode([AudioClip].self, from: data)
        else { return }
        // Keep only clips whose file still exists
        audioClips = clips.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    private func saveAudioLibrary() {
        if let data = try? JSONEncoder().encode(audioClips) {
            try? data.write(to: libraryIndexURL, options: .atomic)
        }
    }

    /// Save 8 kHz mono Int16 samples as a WAV in the library directory and
    /// add an entry for it.
    func addClip(samples: [Int16], name: String) throws {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = clipsDirectory.appendingPathComponent("\(UUID().uuidString)_\(safe).wav")
        try WAVFile.write(samples: samples, to: url)
        let duration = Double(samples.count) / 8000.0
        let clip = AudioClip(name: name, fileURL: url, durationSeconds: duration)
        audioClips.append(clip)
        saveAudioLibrary()
    }

    /// Import an existing WAV — resampled if needed (we only handle 8 kHz mono
    /// for now; reject otherwise so we don't silently misplay).
    func importClip(from sourceURL: URL, name: String) throws {
        let loaded = try WAVFile.read(url: sourceURL)
        let samples: [Int16]
        if loaded.sampleRate == 8000 && loaded.channels == 1 {
            samples = loaded.samples
        } else if loaded.channels == 1 && loaded.sampleRate > 0 {
            // Linear resample (nearest-neighbor) to 8 kHz. Crude but fine for clips.
            let ratio = Double(loaded.sampleRate) / 8000.0
            let outCount = Int(Double(loaded.samples.count) / ratio)
            var out = [Int16](repeating: 0, count: outCount)
            for i in 0..<outCount {
                let src = Int(Double(i) * ratio)
                if src < loaded.samples.count { out[i] = loaded.samples[src] }
            }
            samples = out
        } else {
            throw NSError(domain: "AudioLibrary", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Only mono WAV files are supported (got \(loaded.channels) channels)."
            ])
        }
        try addClip(samples: samples, name: name)
    }

    func deleteClip(_ clip: AudioClip) {
        try? FileManager.default.removeItem(at: clip.fileURL)
        audioClips.removeAll { $0.id == clip.id }
        saveAudioLibrary()
    }

    /// Play a clip through the speakers (for previewing).
    func previewClip(_ clip: AudioClip) {
        guard let loaded = try? WAVFile.read(url: clip.fileURL) else { return }
        audioEngine.enqueuePlayback(samples: loaded.samples)
    }

    /// Play a clip into the active call by feeding samples into the
    /// shared mic buffer. Mic continues to run; the clip is mixed in by
    /// taking priority — actually we just append samples, which means
    /// the clip will play *between* mic frames if mic buffer drains. For
    /// a clean send, you'd want a dedicated source-switch; this is fine
    /// for the simple case where the user pauses talking before pressing.
    func playClipIntoCall(_ clip: AudioClip) {
        guard callInProgress, let loaded = try? WAVFile.read(url: clip.fileURL) else { return }
        callMicBuffer.write(loaded.samples)
        appendLog(.init(direction: .sent, kind: .info,
                        summary: "Queued clip “\(clip.name)” into call (\(loaded.samples.count) samples)"))
    }

    // MARK: - Recording

    func startRecording() {
        Task { @MainActor in
            let ok = await AudioEngine.requestMicAuthorization()
            guard ok else {
                self.appendLog(.init(direction: .sent, kind: .error,
                                     summary: "Microphone access denied"))
                return
            }
            do {
                try self.audioEngine.startRecordMode()
            } catch {
                self.appendLog(.init(direction: .sent, kind: .error,
                                     summary: "Record start failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Stops recording and saves the captured samples as a new clip.
    func stopRecordingAndSave(name: String) {
        let samples = audioEngine.stopRecordMode()
        guard !samples.isEmpty else {
            appendLog(.init(direction: .sent, kind: .error,
                            summary: "Recording produced no samples"))
            return
        }
        do {
            try addClip(samples: samples, name: name)
        } catch {
            appendLog(.init(direction: .sent, kind: .error,
                            summary: "Failed to save clip: \(error.localizedDescription)"))
        }
    }
}
