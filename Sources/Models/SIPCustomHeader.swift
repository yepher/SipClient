import Foundation

/// One arbitrary SIP header to inject into outbound INVITEs.
/// `id` is a stable UUID so SwiftUI `ForEach` row bindings stay rooted
/// when headers are reordered or removed.
struct SIPCustomHeader: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }

    /// Whether the header is complete enough to put on the wire.
    /// Empty rows in the editor are tolerated and skipped on send.
    var isReadyToSend: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
