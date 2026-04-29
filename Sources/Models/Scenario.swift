import Foundation

enum ScenarioStep: Codable, Hashable, Identifiable {
    case waitForAnswer(timeout: Double)
    case wait(seconds: Double)
    case playClip(clipID: UUID)
    case sendDTMF(digits: String)
    case hangup

    var id: String {
        switch self {
        case .waitForAnswer: return "waitForAnswer"
        case .wait(let s): return "wait-\(s)"
        case .playClip(let id): return "playClip-\(id.uuidString)"
        case .sendDTMF(let d): return "dtmf-\(d)"
        case .hangup: return "hangup"
        }
    }

    var displayName: String {
        switch self {
        case .waitForAnswer(let t): return "Wait for answer (\(Int(t))s)"
        case .wait(let s): return "Wait \(s)s"
        case .playClip: return "Play clip"
        case .sendDTMF(let d): return "Send DTMF \(d)"
        case .hangup: return "Hang up"
        }
    }
}

struct Scenario: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var steps: [ScenarioStep]

    init(id: UUID = UUID(), name: String, steps: [ScenarioStep] = []) {
        self.id = id
        self.name = name
        self.steps = steps
    }
}
