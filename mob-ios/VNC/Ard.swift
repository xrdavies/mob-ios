import CommonCrypto
import CryptoKit
import Foundation

/// Apple Remote Desktop authentication (RFB security type 30), used by macOS Screen Sharing to
/// sign in as a macOS user. Unlike VNC Auth, the server then attaches the client to that user's
/// session instead of the login window.
///
/// The server sends a Diffie-Hellman generator, key length, prime and its public key. The client
/// derives the shared secret, uses MD5(secret) as an AES-128 key, and answers with
/// AES-ECB(username[64] ‖ password[64]) followed by its own public key. Ported from svnc.
enum Ard {
    static func randomBytes(_ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return b
    }

    static func response(generator: Int, prime: [UInt8], serverKey: [UInt8], username: String, password: String,
                         random: (Int) -> [UInt8] = randomBytes) -> [UInt8] {
        let keyLength = prime.count
        let privateKey = random(keyLength)
        let g = BigUInt.bytes([UInt32(generator)], length: keyLength)
        let publicKey = BigUInt.modPow(g, privateKey, prime)
        let secret = BigUInt.modPow(serverKey, privateKey, prime)
        let plain = field(username, random) + field(password, random)
        return aesEcb(md5(secret), plain, encrypt: true) + publicKey
    }

    static func md5(_ data: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: data)) }

    static func aesEcb(_ key: [UInt8], _ data: [UInt8], encrypt: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
            key, key.count, nil, data, data.count, &out, out.count, &moved
        )
        precondition(status == kCCSuccess, "AES failed: \(status)")
        return Array(out.prefix(moved))
    }

    /// A NUL-terminated UTF-8 string (max 63 bytes) in a 64-byte field of random filler.
    private static func field(_ value: String, _ random: (Int) -> [UInt8]) -> [UInt8] {
        var out = random(64)
        let bytes = Array(value.utf8.prefix(63))
        out.replaceSubrange(0..<bytes.count, with: bytes)
        out[bytes.count] = 0
        return out
    }
}
