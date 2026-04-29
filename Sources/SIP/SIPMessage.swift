import Foundation
import CryptoKit

/// Parsed SIP response.
struct SIPResponse {
    let raw: String
    let statusCode: Int
    let statusText: String
    /// Lower-cased header name → values. Multi-value headers are stored as a list.
    let headers: [String: [String]]
    let body: String

    func firstHeader(_ name: String) -> String? {
        headers[name.lowercased()]?.first
    }
}

/// Parsed SIP request (used for in-dialog BYE / re-INVITE handling and for UAS).
struct SIPRequest {
    let raw: String
    let method: String
    let requestURI: String
    let headers: [String: [String]]
    let body: String

    func firstHeader(_ name: String) -> String? {
        headers[name.lowercased()]?.first
    }
}

enum SIPParser {
    /// Parse a SIP message — either a request (e.g. "BYE sip:... SIP/2.0") or
    /// a response (e.g. "SIP/2.0 200 OK").
    static func parseMessage(_ data: Data) -> Either<SIPRequest, SIPResponse>? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }

        let (headers, body) = parseHeadersAndBody(lines: Array(lines.dropFirst()))

        if first.hasPrefix("SIP/2.0") {
            let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            let code = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
            let statusText = parts.count >= 3 ? String(parts[2]) : ""
            return .right(SIPResponse(
                raw: text,
                statusCode: code,
                statusText: statusText,
                headers: headers,
                body: body
            ))
        } else {
            // Request line: METHOD URI SIP/2.0
            let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            let method = String(parts[0])
            let uri = String(parts[1])
            return .left(SIPRequest(
                raw: String(data: data, encoding: .utf8) ?? "",
                method: method,
                requestURI: uri,
                headers: headers,
                body: body
            ))
        }
    }

    /// Parse a SIP response. Convenience for callers that only expect responses.
    static func parseResponse(_ data: Data) -> SIPResponse? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, first.hasPrefix("SIP/2.0") else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        let code = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        let statusText = parts.count >= 3 ? String(parts[2]) : ""
        let (headers, body) = parseHeadersAndBody(lines: Array(lines.dropFirst()))
        return SIPResponse(raw: text, statusCode: code, statusText: statusText,
                           headers: headers, body: body)
    }

    private static func parseHeadersAndBody(lines: [String]) -> ([String: [String]], String) {
        var headers: [String: [String]] = [:]
        var bodyLines: [String] = []
        var inBody = false
        for line in lines {
            if inBody {
                bodyLines.append(line)
                continue
            }
            if line.isEmpty {
                inBody = true
                continue
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key, default: []].append(value)
            }
        }
        return (headers, bodyLines.joined(separator: "\r\n"))
    }
}

/// Two-case "Either" used by parseMessage so callers can dispatch on
/// request vs response without a separate type tag.
enum Either<L, R> {
    case left(L)
    case right(R)
}

// MARK: - Header utilities

enum SIPHeaders {
    /// Extract `tag=...` from a To/From header value.
    static func tagParam(_ headerValue: String) -> String? {
        guard let r = headerValue.range(of: "tag=") else { return nil }
        let after = headerValue[r.upperBound...]
        let end = after.firstIndex(of: ";") ?? after.endIndex
        return String(after[..<end]).trimmingCharacters(in: .whitespaces)
    }

    /// Parse a comma-separated `Digest k="v", k2="v2"` header into a key/value map.
    static func parseAuthChallenge(_ value: String) -> [String: String] {
        var s = value
        if s.lowercased().hasPrefix("digest ") {
            s = String(s.dropFirst(7))
        }
        var result: [String: String] = [:]
        // Split on commas, but careful: values may contain spaces. They do
        // NOT contain commas in well-formed headers.
        for part in s.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let k = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var v = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            result[k] = String(v)
        }
        return result
    }
}

// MARK: - Digest auth

enum DigestAuth {
    /// Compute the SIP digest auth response (RFC 2617, MD5).
    static func response(
        username: String,
        realm: String,
        password: String,
        nonce: String,
        method: String,
        uri: String
    ) -> String {
        let ha1 = md5("\(username):\(realm):\(password)")
        let ha2 = md5("\(method):\(uri)")
        return md5("\(ha1):\(nonce):\(ha2)")
    }

    private static func md5(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Random tokens

enum SIPTokens {
    private static let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    static func callID() -> String {
        return "\(rand(16))@sip-client"
    }

    static func branch() -> String {
        return "z9hG4bK\(rand(12))"
    }

    static func tag() -> String {
        return rand(8)
    }

    private static func rand(_ length: Int) -> String {
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}
