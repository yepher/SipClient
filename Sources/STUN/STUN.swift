import Foundation

struct STUNResult {
    let publicIP: String
    let publicPort: UInt16
}

enum STUN {
    private static let defaultServers: [(host: String, port: UInt16)] = [
        ("stun.l.google.com", 19302),
        ("stun1.l.google.com", 19302),
        ("stun.cloudflare.com", 3478),
    ]

    /// Send a STUN binding request on `socket` and parse the XOR-MAPPED-ADDRESS
    /// (or MAPPED-ADDRESS) attribute from the response.
    /// Returns nil if no STUN server responds within `timeout`.
    static func discover(
        socket: UDPSocket,
        server: String? = nil,
        port: UInt16 = 3478,
        timeout: TimeInterval = 3.0
    ) -> STUNResult? {
        let candidates: [(String, UInt16)]
        if let server, !server.isEmpty {
            candidates = [(server, port)]
        } else {
            candidates = defaultServers
        }

        // Build STUN binding request
        var txID = Data(count: 12)
        for i in 0..<12 { txID[i] = UInt8.random(in: 0...255) }
        var msg = Data()
        msg.append(contentsOf: [0x00, 0x01]) // type: Binding Request
        msg.append(contentsOf: [0x00, 0x00]) // length
        msg.append(contentsOf: [0x21, 0x12, 0xA4, 0x42]) // magic cookie
        msg.append(txID)

        for (host, p) in candidates {
            do {
                try socket.send(msg, to: host, port: p)
            } catch {
                continue
            }

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                guard let received = (try? socket.recvOnce(timeout: 0.5)) ?? nil else {
                    continue
                }
                let data = received.data
                guard data.count >= 20,
                      data[0] == 0x01, data[1] == 0x01,
                      data.subdata(in: 4..<8) == Data([0x21, 0x12, 0xA4, 0x42]),
                      data.subdata(in: 8..<20) == txID
                else { continue }

                let totalLen = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
                guard data.count >= 20 + totalLen else { continue }

                if let result = parseAttributes(data: data, bodyLen: totalLen) {
                    return result
                }
            }
        }
        return nil
    }

    private static func parseAttributes(data: Data, bodyLen: Int) -> STUNResult? {
        var idx = 20
        let end = 20 + bodyLen
        while idx + 4 <= end {
            let attrType = (UInt16(data[idx]) << 8) | UInt16(data[idx + 1])
            let attrLen = Int((UInt16(data[idx + 2]) << 8) | UInt16(data[idx + 3]))
            idx += 4
            let bodyEnd = idx + attrLen
            guard bodyEnd <= end else { return nil }

            // 0x0020 XOR-MAPPED-ADDRESS, 0x0001 MAPPED-ADDRESS
            if (attrType == 0x0020 || attrType == 0x0001) && attrLen >= 8 {
                let family = data[idx + 1]
                if family == 0x01 {  // IPv4
                    var port = (UInt16(data[idx + 2]) << 8) | UInt16(data[idx + 3])
                    var ip0 = data[idx + 4]
                    var ip1 = data[idx + 5]
                    var ip2 = data[idx + 6]
                    var ip3 = data[idx + 7]
                    if attrType == 0x0020 {
                        port ^= 0x2112
                        ip0 ^= 0x21
                        ip1 ^= 0x12
                        ip2 ^= 0xA4
                        ip3 ^= 0x42
                    }
                    let ip = "\(ip0).\(ip1).\(ip2).\(ip3)"
                    return STUNResult(publicIP: ip, publicPort: port)
                }
            }
            // attributes are 4-byte aligned
            let pad = (4 - (attrLen % 4)) % 4
            idx = bodyEnd + pad
        }
        return nil
    }
}
