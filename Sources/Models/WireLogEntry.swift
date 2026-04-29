import Foundation

enum WireDirection: String, Codable {
    case sent
    case received
}

enum WireKind: String, Codable {
    case sip
    case rtpStat
    case info
    case error
}

struct WireLogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let direction: WireDirection
    let kind: WireKind
    let summary: String
    let detail: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        direction: WireDirection,
        kind: WireKind,
        summary: String,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.direction = direction
        self.kind = kind
        self.summary = summary
        self.detail = detail
    }
}
