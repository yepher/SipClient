import Foundation

/// Transport used to carry SIP signalling.
enum SIPTransportKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case udp
    case tcp
    case tls

    var id: String { rawValue }
    var displayName: String { rawValue.uppercased() }
    var viaName: String { rawValue.uppercased() }
    var defaultPort: UInt16 { self == .tls ? 5061 : 5060 }
    /// UDP needs INVITE retransmits per RFC 3261 §17.1.1.2; TCP/TLS don't.
    var requiresRetransmits: Bool { self == .udp }
    /// SIP URI scheme that implies this transport.
    var sipScheme: String { self == .tls ? "sips" : "sip" }
}

enum SIPTransportError: Error, LocalizedError {
    case connectTimeout(host: String, port: UInt16)
    case connectFailed(String)
    case sendFailed(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .connectTimeout(let h, let p): return "Connect to \(h):\(p) timed out"
        case .connectFailed(let m): return "Connect failed: \(m)"
        case .sendFailed(let m): return "Send failed: \(m)"
        case .closed: return "Transport closed"
        }
    }
}

/// One-message-at-a-time bidirectional channel to a SIP peer.
///
/// For datagram transports (UDP) one `recvMessage` returns a single datagram.
/// For stream transports (TCP, TLS) the receive loop reassembles framed SIP
/// messages using `Content-Length` headers per RFC 3261 §7.5.
protocol SIPTransport: AnyObject {
    var kind: SIPTransportKind { get }
    /// Local IPv4 address visible to the peer (for Via / Contact / SDP).
    var localIP: String { get }
    var localPort: UInt16 { get }

    /// Set up underlying socket / connection. Blocks until ready.
    func start() throws
    /// Send raw bytes (one whole SIP message) to the peer.
    func send(_ data: Data) throws
    /// Send to a specific host:port — used for in-dialog requests routed
    /// per RFC 3261 §12.2.1 (route-set first hop) and for responses sent
    /// per §18.2.2 (topmost Via). Only UDP can vary the destination per
    /// message; stream transports are bound to their connection so the
    /// default implementation falls back to `send(_:)`.
    func send(_ data: Data, to host: String, port: UInt16) throws
    /// Block up to `timeout` for the next complete SIP message. Returns
    /// `nil` on timeout.
    func recvMessage(timeout: TimeInterval) throws -> Data?
    func close()
}

extension SIPTransport {
    func send(_ data: Data, to host: String, port: UInt16) throws {
        try send(data)
    }
}

// MARK: - UDP

/// SIP-over-UDP transport. Wraps `UDPSocket` and a fixed target endpoint.
final class UDPSIPTransport: SIPTransport, @unchecked Sendable {
    let kind: SIPTransportKind = .udp
    let socket: UDPSocket
    let targetHost: String
    let targetPort: UInt16
    let localIP: String
    var localPort: UInt16 { socket.localPort }

    init(targetHost: String, targetPort: UInt16, localPort: UInt16) throws {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.socket = try UDPSocket(localPort: localPort)
        self.localIP = try UDPSocket.detectLocalIP(targetHost: targetHost,
                                                   targetPort: targetPort)
    }

    func start() throws { /* nothing to do */ }

    func send(_ data: Data) throws {
        try socket.send(data, to: targetHost, port: targetPort)
    }

    func send(_ data: Data, to host: String, port: UInt16) throws {
        try socket.send(data, to: host, port: port)
    }

    func recvMessage(timeout: TimeInterval) throws -> Data? {
        return try socket.recvOnce(timeout: timeout)?.data
    }

    func close() { /* fd closed in UDPSocket.deinit */ }
}
