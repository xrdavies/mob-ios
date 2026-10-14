import CommonCrypto
import Foundation

/// Classic VNC Authentication (RFB security type 2): the 16-byte challenge encrypted with DES,
/// keyed by the password (max 8 bytes, zero-padded) with each key byte's bits reversed.
/// Signs in to the login window, not a user's session (that needs Apple sign-in, type 30).
enum VncAuth {
    static func response(password: String, challenge: [UInt8]) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        for (i, b) in password.unicodeScalars.prefix(8).enumerated() { key[i] = reverseBits(UInt8(truncatingIfNeeded: b.value)) }
        return des(key, challenge)
    }

    static func des(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeDES)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                             key, kCCKeySizeDES, nil, data, data.count, &out, out.count, &moved)
        precondition(status == kCCSuccess, "DES failed: \(status)")
        return Array(out.prefix(moved))
    }

    static func reverseBits(_ b: UInt8) -> UInt8 {
        var v = b, r: UInt8 = 0
        for _ in 0..<8 {
            r = (r << 1) | (v & 1)
            v >>= 1
        }
        return r
    }
}
