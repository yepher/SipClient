import Foundation
import Network

/// SIP-over-TCP or SIP-over-TLS transport. Built on `NWConnection` (which
/// handles TLS via Apple's modern stack). The class keeps a fixed-size
/// receive buffer, parses SIP messages framed by `Content-Length` per
/// RFC 3261 §7.5, and exposes a synchronous `recvMessage` that blocks
/// until a full message is available.
///
/// Synchronous interface is bridged onto NWConnection's async callbacks
/// using a `DispatchSemaphore` for `start` and `send`, and a polling
/// loop with `NSCondition` for `recvMessage`. Matches the existing
/// `SIPCall.run()` style.
final class StreamSIPTransport: SIPTransport, @unchecked Sendable {
    let kind: SIPTransportKind
    let targetHost: String
    let targetPort: UInt16

    /// When true, accept any TLS server certificate (good for dev /
    /// self-signed setups; off by default in TLS production usage).
    let allowSelfSignedTLS: Bool

    private(set) var localIP: String = ""
    private(set) var localPort: UInt16 = 0

    private let connection: NWConnection
    private let queue: DispatchQueue

    private let bufferLock = NSCondition()
    private var receivedBuffer = Data()
    private var receiveError: Error?
    private var connectionEnded = false

    init(targetHost: String,
         targetPort: UInt16,
         kind: SIPTransportKind,
         allowSelfSignedTLS: Bool = true) throws {
        precondition(kind == .tcp || kind == .tls, "use UDPSIPTransport for UDP")
        self.kind = kind
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.allowSelfSignedTLS = allowSelfSignedTLS
        self.queue = DispatchQueue(label: "SIPTransport.\(kind.rawValue)")

        guard let port = NWEndpoint.Port(rawValue: targetPort) else {
            throw SIPTransportError.connectFailed("invalid port \(targetPort)")
        }
        let host = NWEndpoint.Host(targetHost)

        let params: NWParameters
        if kind == .tls {
            let tlsOptions = NWProtocolTLS.Options()
            if allowSelfSignedTLS {
                let secOptions = tlsOptions.securityProtocolOptions
                sec_protocol_options_set_verify_block(
                    secOptions,
                    { _, _, completion in completion(true) },
                    queue
                )
            }
            params = NWParameters(tls: tlsOptions)
        } else {
            params = NWParameters.tcp
        }
        params.allowLocalEndpointReuse = true

        self.connection = NWConnection(host: host, port: port, using: params)
    }

    func start() throws {
        let sem = DispatchSemaphore(value: 0)
        var startError: Error?
        var signaled = false

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.captureLocalEndpoint()
                if !signaled { signaled = true; sem.signal() }
            case .failed(let err):
                startError = err
                self.signalEnded(error: err)
                if !signaled { signaled = true; sem.signal() }
            case .cancelled:
                self.signalEnded(error: nil)
                if !signaled { signaled = true; sem.signal() }
            default:
                break
            }
        }
        connection.start(queue: queue)

        let r = sem.wait(timeout: .now() + 10)
        if r == .timedOut {
            connection.cancel()
            throw SIPTransportError.connectTimeout(host: targetHost, port: targetPort)
        }
        if let err = startError {
            throw SIPTransportError.connectFailed(err.localizedDescription)
        }

        beginReceiving()
    }

    private func captureLocalEndpoint() {
        // currentPath?.localEndpoint isn't always populated immediately;
        // fall back to inspecting the connection's local endpoint.
        let endpoint = connection.currentPath?.localEndpoint ?? connection.endpoint
        if case let .hostPort(host, port) = endpoint {
            localPort = port.rawValue
            switch host {
            case .ipv4(let addr):
                localIP = "\(addr)"
            case .ipv6(let addr):
                localIP = "\(addr)"
            case .name(let name, _):
                localIP = name
            @unknown default:
                break
            }
        }
    }

    private func beginReceiving() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.bufferLock.lock()
                self.receivedBuffer.append(data)
                self.bufferLock.broadcast()
                self.bufferLock.unlock()
            }
            if let error {
                self.signalEnded(error: error)
                return
            }
            if isComplete {
                self.signalEnded(error: nil)
                return
            }
            self.beginReceiving()
        }
    }

    private func signalEnded(error: Error?) {
        bufferLock.lock()
        connectionEnded = true
        receiveError = error
        bufferLock.broadcast()
        bufferLock.unlock()
    }

    func send(_ data: Data) throws {
        let sem = DispatchSemaphore(value: 0)
        var sendError: NWError?
        connection.send(content: data, completion: .contentProcessed { err in
            sendError = err
            sem.signal()
        })
        sem.wait()
        if let err = sendError {
            throw SIPTransportError.sendFailed(err.localizedDescription)
        }
    }

    func recvMessage(timeout: TimeInterval) throws -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        bufferLock.lock()
        defer { bufferLock.unlock() }

        while true {
            if let msg = Self.extractFramedMessage(from: receivedBuffer) {
                receivedBuffer.removeFirst(msg.count)
                return msg
            }
            if let err = receiveError {
                throw SIPTransportError.connectFailed(err.localizedDescription)
            }
            if connectionEnded {
                throw SIPTransportError.closed
            }
            let now = Date()
            if now >= deadline { return nil }
            _ = bufferLock.wait(until: deadline)
        }
    }

    func close() {
        connection.cancel()
    }

    /// RFC 3261 §7.5: a SIP message framed on a stream is the headers
    /// terminated by `\r\n\r\n` followed by exactly `Content-Length`
    /// bytes of body. Returns the message including headers + body, or
    /// nil if not enough has been received yet.
    ///
    /// Note: `buffer` may be a slice with `startIndex > 0` (we keep
    /// appending to and `removeFirst`-ing the same `Data`). All indices
    /// returned by `Data.range(of:)` and slice subscripts are absolute,
    /// so we use `buffer.startIndex` everywhere instead of `0`.
    static func extractFramedMessage(from buffer: Data) -> Data? {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        let bodyStart = headerEnd.upperBound

        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        var contentLength = 0
        for line in headerStr.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let raw = line.dropFirst("content-length:".count)
                if let n = Int(raw.trimmingCharacters(in: .whitespaces)) {
                    contentLength = n
                }
                break
            } else if lower.hasPrefix("l:") {  // RFC 3261 short form
                let raw = line.dropFirst("l:".count)
                if let n = Int(raw.trimmingCharacters(in: .whitespaces)) {
                    contentLength = n
                }
                break
            }
        }
        let totalEnd = bodyStart + contentLength
        guard totalEnd <= buffer.endIndex else { return nil }
        // Copy into a fresh Data so the returned message has
        // startIndex == 0 (caller's `msg.count` math doesn't depend on
        // the source slice's offset).
        return Data(buffer[buffer.startIndex..<totalEnd])
    }
}
