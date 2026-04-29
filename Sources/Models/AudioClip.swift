import Foundation

struct AudioClip: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var fileURL: URL
    var durationSeconds: Double
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        fileURL: URL,
        durationSeconds: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.fileURL = fileURL
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
    }
}
