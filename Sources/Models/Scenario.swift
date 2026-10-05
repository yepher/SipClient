import Foundation

enum ScenarioStep: Codable, Hashable, Identifiable {
    case waitForAnswer(timeout: Double)
    case wait(seconds: Double)
    case playClip(clipID: UUID)
    case sendDTMF(digits: String)
    case hangup
    /// Wait up to `timeout` seconds for the far end to start talking, then
    /// let them finish (the scenario's end-of-turn silence) before moving
    /// on. Fails if no speech is heard in time.
    case waitForSpeech(timeout: Double)
    /// Speak `text` into the call with the system voice.
    case speak(text: String)

    var id: String {
        switch self {
        case .waitForAnswer(let t): return "waitForAnswer-\(t)"
        case .wait(let s): return "wait-\(s)"
        case .playClip(let cid): return "playClip-\(cid.uuidString)"
        case .sendDTMF(let d): return "dtmf-\(d)"
        case .hangup: return "hangup"
        case .waitForSpeech(let t): return "waitForSpeech-\(t)"
        case .speak(let text): return "speak-\(text)"
        }
    }

    var typeLabel: String {
        switch self {
        case .waitForAnswer: return "Wait for answer"
        case .wait: return "Wait"
        case .playClip: return "Play clip"
        case .sendDTMF: return "Send DTMF"
        case .hangup: return "Hang up"
        case .waitForSpeech: return "Wait for far-end speech"
        case .speak: return "Speak text"
        }
    }
}

/// What to do with per-iteration call recordings in a repeated run.
enum ScenarioRecordingPolicy: String, Codable, CaseIterable, Identifiable {
    case off
    case failuresOnly
    case all

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off:          return "Don't record"
        case .failuresOnly: return "Keep failed calls"
        case .all:          return "Keep all calls"
        }
    }
}

struct Scenario: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    /// If set, running this scenario places a call from this profile first.
    var profileID: UUID?
    var steps: [ScenarioStep]

    /// Times to run the whole scenario, each on a fresh call. Above 1 a
    /// profile is required, and each iteration is hung up when its steps
    /// finish.
    var repeatCount: Int = 1
    /// Gap between one iteration's call ending and the next starting.
    var pauseBetweenRuns: Double = 2
    /// Inbound frames at or above this level count as far-end speech.
    var speechThresholdDbfs: Double = -40
    /// Far-end speech is "finished" after this much continuous silence.
    var endOfTurnSilence: Double = 1.0
    /// Send silence instead of the live microphone while the scenario
    /// runs, so only the scenario's own prompts reach the far end.
    var ignoreMicrophone: Bool = true
    var recordingPolicy: ScenarioRecordingPolicy = .failuresOnly

    init(id: UUID = UUID(),
         name: String,
         profileID: UUID? = nil,
         steps: [ScenarioStep] = [],
         repeatCount: Int = 1) {
        self.id = id
        self.name = name
        self.profileID = profileID
        self.steps = steps
        self.repeatCount = repeatCount
    }

    /// A copy with a fresh ID, keeping every setting.
    func duplicate(named newName: String) -> Scenario {
        var copy = Scenario(name: newName, profileID: profileID, steps: steps,
                            repeatCount: repeatCount)
        copy.pauseBetweenRuns = pauseBetweenRuns
        copy.speechThresholdDbfs = speechThresholdDbfs
        copy.endOfTurnSilence = endOfTurnSilence
        copy.ignoreMicrophone = ignoreMicrophone
        copy.recordingPolicy = recordingPolicy
        return copy
    }

    /// Ready-made one-way-audio check: hear the agent, ask it something,
    /// hear it answer. Each direction of media has to work to pass.
    static func agentRoundTripTemplate(profileID: UUID?) -> Scenario {
        Scenario(name: "Agent round-trip ×100",
                 profileID: profileID,
                 steps: [
                    .waitForAnswer(timeout: 30),
                    .waitForSpeech(timeout: 15),
                    .speak(text: "What is the capital of Illinois?"),
                    .waitForSpeech(timeout: 20),
                    .hangup,
                 ],
                 repeatCount: 100)
    }

    /// Decodes scenarios saved before the run settings existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        steps = try c.decode([ScenarioStep].self, forKey: .steps)
        repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1
        pauseBetweenRuns = try c.decodeIfPresent(Double.self, forKey: .pauseBetweenRuns) ?? 2
        speechThresholdDbfs = try c.decodeIfPresent(Double.self, forKey: .speechThresholdDbfs) ?? -40
        endOfTurnSilence = try c.decodeIfPresent(Double.self, forKey: .endOfTurnSilence) ?? 1.0
        ignoreMicrophone = try c.decodeIfPresent(Bool.self, forKey: .ignoreMicrophone) ?? true
        recordingPolicy = (try? c.decodeIfPresent(ScenarioRecordingPolicy.self,
                                                  forKey: .recordingPolicy)) ?? .failuresOnly
    }
}

// MARK: - Run reports

/// Outcome of one iteration (one call) of a scenario run.
struct ScenarioIterationResult: Codable, Identifiable, Hashable {
    var id: Int { iteration }
    var iteration: Int
    var startedAt: Date
    /// SIP Call-ID of the INVITE we sent.
    var callID: String
    var passed: Bool
    var failedStep: Int?
    var failedStepLabel: String?
    var reason: String?
    /// Status of the last final response to the INVITE (200, 486, …).
    var sipStatus: Int?
    /// `X-*` headers from that response — server-side correlation IDs.
    var correlationHeaders: [String: String] = [:]
    var answerMs: Int?
    /// From answer to the first far-end speech.
    var firstSpeechMs: Int?
    /// From the end of our last prompt to the far end's reply.
    var responseLatencyMs: Int?
    var rtpPacketsReceived: Int = 0
    var recordingPath: String?
}

struct ScenarioRunReport: Codable, Identifiable {
    var id: UUID = UUID()
    var scenarioID: UUID
    var scenarioName: String
    var profileName: String
    var startedAt: Date
    var endedAt: Date?
    var plannedIterations: Int
    var cancelled = false
    var results: [ScenarioIterationResult] = []

    var passed: Int { results.filter(\.passed).count }
    var failed: Int { results.count - passed }
    var successRate: Double {
        results.isEmpty ? 0 : Double(passed) / Double(results.count)
    }
    var failures: [ScenarioIterationResult] { results.filter { !$0.passed } }

    var summaryLine: String {
        String(format: "%@: %d/%d calls, %d passed, %d failed — %.1f%% success",
               scenarioName, results.count, plannedIterations, passed, failed,
               successRate * 100)
    }

    /// Plain-text report for pasting into a ticket or Slack.
    var textReport: String {
        let df = ISO8601DateFormatter()
        var s = "\(summaryLine)\n"
        s += "Profile: \(profileName)\n"
        s += "Started: \(df.string(from: startedAt))"
        if let endedAt { s += "  Ended: \(df.string(from: endedAt))" }
        if cancelled { s += "  (cancelled)" }
        s += "\n"
        if failures.isEmpty {
            s += "\nNo failures.\n"
        } else {
            s += "\nFailed calls to review:\n"
            for f in failures {
                s += "#\(f.iteration)  \(df.string(from: f.startedAt))  Call-ID: \(f.callID)\n"
                for (k, v) in f.correlationHeaders.sorted(by: { $0.key < $1.key }) {
                    s += "    \(k): \(v)\n"
                }
                s += "    step \((f.failedStep ?? -1) + 1) (\(f.failedStepLabel ?? "?")): \(f.reason ?? "")\n"
                if let r = f.recordingPath { s += "    recording: \(r)\n" }
            }
        }
        return s
    }

    var csv: String {
        let df = ISO8601DateFormatter()
        func q(_ s: String?) -> String {
            "\"\((s ?? "").replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        func n(_ v: Int?) -> String { v.map(String.init) ?? "" }
        var s = "iteration,started_at,result,call_id,sip_status,failed_step,reason,"
            + "answer_ms,first_speech_ms,response_latency_ms,rtp_packets_received,"
            + "correlation_headers,recording\n"
        for r in results {
            let headers = r.correlationHeaders.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            s += [String(r.iteration), df.string(from: r.startedAt),
                  r.passed ? "pass" : "fail", q(r.callID), n(r.sipStatus),
                  r.failedStep.map { q("\($0 + 1) \(r.failedStepLabel ?? "")") } ?? "",
                  q(r.reason), n(r.answerMs), n(r.firstSpeechMs),
                  n(r.responseLatencyMs), String(r.rtpPacketsReceived),
                  q(headers), q(r.recordingPath)].joined(separator: ",") + "\n"
        }
        return s
    }
}
