import Darwin
import Foundation

enum UDPError: Error, LocalizedError {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case connectFailed(Int32)
    case sendFailed(Int32)
    case recvFailed(Int32)
    case dnsFailed(host: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .socketFailed(let e): return "socket() failed (errno \(e))"
        case .bindFailed(let e): return "bind() failed (errno \(e))"
        case .connectFailed(let e): return "connect() failed (errno \(e))"
        case .sendFailed(let e): return "sendto() failed (errno \(e))"
        case .recvFailed(let e): return "recvfrom() failed (errno \(e))"
        case .dnsFailed(let host, let code):
            return "DNS resolution failed for \(host) (rc=\(code))"
        }
    }
}

/// Thin wrapper around a non-connected BSD UDP socket.
///
/// Used for both SIP signalling and RTP — same shape as the Python
/// `socket.socket(AF_INET, SOCK_DGRAM)` usage in `sip_e2e_tester`.
final class UDPSocket: @unchecked Sendable {
    let fd: Int32
    let localPort: UInt16

    init(localPort: UInt16 = 0, recvBufferSize: Int = 1024 * 1024) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw UDPError.socketFailed(errno) }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var rbuf = Int32(recvBufferSize)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rbuf, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = localPort.bigEndian
        addr.sin_addr.s_addr = 0  // INADDR_ANY

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw UDPError.bindFailed(e)
        }
        self.fd = fd

        var bound = sockaddr_in()
        var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &blen)
            }
        }
        self.localPort = UInt16(bigEndian: bound.sin_port)
    }

    deinit { close(fd) }

    func send(_ data: Data, to host: String, port: UInt16) throws {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        sin.sin_addr = try Self.resolveIPv4(host)

        let sent: Int = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.sendto(fd, raw.baseAddress, raw.count, 0, sa,
                                  socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { throw UDPError.sendFailed(errno) }
    }

    /// Blocking receive with a timeout. Returns `nil` on timeout.
    func recvOnce(timeout: TimeInterval) throws -> (data: Data, host: String, port: UInt16)? {
        var tv = timeval()
        tv.tv_sec = Int(timeout)
        tv.tv_usec = Int32((timeout - Double(tv.tv_sec)) * 1_000_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 8192)
        var sin = sockaddr_in()
        var slen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n: Int = buf.withUnsafeMutableBytes { raw in
            withUnsafeMutablePointer(to: &sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.recvfrom(fd, raw.baseAddress, raw.count, 0, sa, &slen)
                }
            }
        }
        if n < 0 {
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK { return nil }
            throw UDPError.recvFailed(e)
        }
        let data = Data(buf[0..<n])
        var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        _ = withUnsafePointer(to: &sin.sin_addr) {
            inet_ntop(AF_INET, $0, &ipBuf, socklen_t(INET_ADDRSTRLEN))
        }
        let host = String(cString: ipBuf)
        return (data, host, UInt16(bigEndian: sin.sin_port))
    }

    static func resolveIPv4(_ host: String) throws -> in_addr {
        var literal = in_addr()
        if inet_pton(AF_INET, host, &literal) == 1 {
            return literal
        }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &info)
        guard rc == 0, let info else {
            throw UDPError.dnsFailed(host: host, code: rc)
        }
        defer { freeaddrinfo(info) }
        let sin = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            $0.pointee
        }
        return sin.sin_addr
    }

    /// Detect our outbound IPv4 by seeing which interface routes to `targetHost`.
    static func detectLocalIP(targetHost: String, targetPort: UInt16 = 5060) throws -> String {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { throw UDPError.socketFailed(errno) }
        defer { close(s) }

        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = targetPort.bigEndian
        sin.sin_addr = try resolveIPv4(targetHost)

        let rc = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw UDPError.connectFailed(errno) }

        var local = sockaddr_in()
        var llen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(s, $0, &llen)
            }
        }
        var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        _ = withUnsafePointer(to: &local.sin_addr) {
            inet_ntop(AF_INET, $0, &ipBuf, socklen_t(INET_ADDRSTRLEN))
        }
        return String(cString: ipBuf)
    }
}
