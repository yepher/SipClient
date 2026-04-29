import Foundation

enum ScenarioStep: Codable, Hashable, Identifiable {
    case waitForAnswer(timeout: Double)
    case wait(seconds: Double)
    case playClip(clipID: UUID)
    case sendDTMF(digits: String)
    case hangup

    var id: String {
        switch self {
        case .waitForAnswer(let t): return "waitForAnswer-\(t)"
        case .wait(let s): return "wait-\(s)"
        case .playClip(let cid): return "playClip-\(cid.uuidString)"
        case .sendDTMF(let d): return "dtmf-\(d)"
        case .hangup: return "hangup"
        }
    }

    var typeLabel: String {
        switch self {
        case .waitForAnswer: return "Wait for answer"
        case .wait: return "Wait"
        case .playClip: return "Play clip"
        case .sendDTMF: return "Send DTMF"
        case .hangup: return "Hang up"
        }
    }
}

struct Scenario: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    /// If set, running this scenario places a call from this profile first.
    var profileID: UUID?
    var steps: [ScenarioStep]

    init(id: UUID = UUID(),
         name: String,
         profileID: UUID? = nil,
         steps: [ScenarioStep] = []) {
        self.id = id
        self.name = name
        self.profileID = profileID
        self.steps = steps
    }
}
