import CommonCrypto
import Foundation

/// Low-level crypto primitives needed by SRTP per RFC 3711.
///
/// AES-128 in counter (CTR) mode for stream encryption, HMAC-SHA1
/// truncated to 80 bits for packet authentication, plus the SRTP key
/// derivation function (KDF) that produces session keys from a master
/// key and master salt.
enum SRTPCrypto {

    /// AES-128-CTR encrypt/decrypt (symmetric — CTR mode is its own
    /// inverse). `key` must be 16 bytes; `iv` (initial counter) must be
    /// 16 bytes; counter increments by 1 per AES block.
    static func aesCTR(key: Data, iv: Data, input: Data) -> Data {
        precondition(key.count == 16, "AES-128 key must be 16 bytes")
        precondition(iv.count == 16, "AES IV must be 16 bytes")

        var output = Data(count: input.count)
        var cryptor: CCCryptorRef?

        let status = key.withUnsafeBytes { keyPtr -> CCCryptorStatus in
            iv.withUnsafeBytes { ivPtr -> CCCryptorStatus in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivPtr.baseAddress,
                    keyPtr.baseAddress, keyPtr.count,
                    nil, 0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard status == kCCSuccess, let cryptor else { return Data() }
        defer { CCCryptorRelease(cryptor) }

        var moved = 0
        let updateStatus = input.withUnsafeBytes { inPtr -> CCCryptorStatus in
            output.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
                CCCryptorUpdate(
                    cryptor,
                    inPtr.baseAddress, inPtr.count,
                    outPtr.baseAddress, outPtr.count,
                    &moved
                )
            }
        }
        guard updateStatus == kCCSuccess else { return Data() }
        return output.prefix(moved)
    }

    /// HMAC-SHA1 truncated to 80 bits (10 bytes) — RFC 3711 §3.4.
    static func hmacSHA1_80(key: Data, data: Data) -> Data {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyPtr.baseAddress, keyPtr.count,
                    dataPtr.baseAddress, dataPtr.count,
                    &mac
                )
            }
        }
        return Data(mac.prefix(10))
    }

    /// SRTP KDF (RFC 3711 §4.3.1).
    ///
    /// Derive a session key of `outputLength` bytes for the given label
    /// from a 16-byte master key and 14-byte master salt. We always use
    /// `index = 0` and the default `key_derivation_rate = 0`, so a single
    /// derivation per session is enough (re-keying is not implemented).
    static func deriveKey(masterKey: Data,
                          masterSalt: Data,
                          label: UInt8,
                          outputLength: Int) -> Data {
        precondition(masterKey.count == 16, "master key must be 16 bytes")
        precondition(masterSalt.count == 14, "master salt must be 14 bytes")

        // x = master_salt XOR (label << 48)
        // The label byte sits at index 7 of the 14-byte salt (counting
        // from 0). The 7th-from-the-right byte gets XOR'd with the label.
        var x = [UInt8](masterSalt)
        x[7] ^= label

        // IV = x || 0x0000  (pad to 16 bytes)
        var iv = Data(x)
        iv.append(contentsOf: [0, 0])

        // PRF input = enough zero bytes to fill outputLength bytes.
        let zeros = Data(count: outputLength)
        return aesCTR(key: masterKey, iv: iv, input: zeros)
    }
}
