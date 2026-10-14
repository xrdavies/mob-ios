import Foundation

/// Just enough big-integer arithmetic for the Apple Remote Desktop Diffie-Hellman exchange:
/// modular exponentiation with an odd modulus, using Montgomery multiplication on 32-bit limbs.
enum BigUInt {
    /// Big-endian bytes to little-endian limbs (at least `count` limbs).
    static func limbs(_ bytes: [UInt8], count: Int = 0) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: max(count, (bytes.count + 3) / 4))
        for (i, byte) in bytes.reversed().enumerated() { out[i / 4] |= UInt32(byte) << (8 * (i % 4)) }
        return out
    }

    /// Little-endian limbs to big-endian bytes, left-padded or truncated to `length`.
    static func bytes(_ limbs: [UInt32], length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        for i in 0..<length {
            let limb = i / 4
            guard limb < limbs.count else { break }
            out[length - 1 - i] = UInt8(truncatingIfNeeded: limbs[limb] >> (8 * (i % 4)))
        }
        return out
    }

    private static func greaterOrEqual(_ a: ArraySlice<UInt32>, _ n: [UInt32]) -> Bool {
        for i in stride(from: n.count - 1, through: 0, by: -1) {
            let x = a[a.startIndex + i]
            if x != n[i] { return x > n[i] }
        }
        return true
    }

    private static func subtract(_ a: inout [UInt32], _ n: [UInt32]) {
        var borrow: Int64 = 0
        for i in 0..<n.count {
            let d = Int64(a[i]) - Int64(n[i]) - borrow
            a[i] = UInt32(truncatingIfNeeded: d)
            borrow = d < 0 ? 1 : 0
        }
    }

    /// (base ^ exp) mod m, all big-endian; m must be odd. The result has m's length.
    static func modPow(_ base: [UInt8], _ exp: [UInt8], _ mod: [UInt8]) -> [UInt8] {
        let n = limbs(mod)
        let k = n.count
        precondition(n[0] & 1 == 1, "modulus must be odd")

        // -n^-1 mod 2^32 by Newton iteration.
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- n[0] &* inv) }
        let n0 = 0 &- inv

        func montMul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
            var t = [UInt32](repeating: 0, count: k + 2)
            for i in 0..<k {
                var c: UInt64 = 0
                let bi = UInt64(b[i])
                for j in 0..<k {
                    let s = UInt64(t[j]) + UInt64(a[j]) * bi + c
                    t[j] = UInt32(truncatingIfNeeded: s)
                    c = s >> 32
                }
                var s = UInt64(t[k]) + c
                t[k] = UInt32(truncatingIfNeeded: s)
                t[k + 1] = UInt32(s >> 32)
                let m = UInt64(t[0] &* n0)
                s = UInt64(t[0]) + m * UInt64(n[0])
                c = s >> 32
                for j in 1..<k {
                    s = UInt64(t[j]) + m * UInt64(n[j]) + c
                    t[j - 1] = UInt32(truncatingIfNeeded: s)
                    c = s >> 32
                }
                s = UInt64(t[k]) + c
                t[k - 1] = UInt32(truncatingIfNeeded: s)
                t[k] = t[k + 1] &+ UInt32(s >> 32)
                t[k + 1] = 0
            }
            var r = Array(t[0..<k])
            if t[k] != 0 || greaterOrEqual(r[...], n) { subtract(&r, n) }
            return r
        }

        // R^2 mod n: start from 1 and double 2 * 32k times.
        var r2 = [UInt32](repeating: 0, count: k)
        r2[0] = 1
        for _ in 0..<(64 * k) {
            var carry: UInt32 = 0
            for i in 0..<k {
                let v = r2[i]
                r2[i] = (v << 1) | carry
                carry = v >> 31
            }
            if carry != 0 || greaterOrEqual(r2[...], n) { subtract(&r2, n) }
        }

        var one = [UInt32](repeating: 0, count: k)
        one[0] = 1
        // ARD bases (generator, server key) are shorter than or as long as the prime.
        precondition(base.count <= mod.count, "base longer than the modulus")
        var b = limbs(base, count: k)
        // A base at or just above the modulus is reduced the slow way (not expected in ARD).
        while greaterOrEqual(b[...], n) { subtract(&b, n) }
        let bm = montMul(b, r2)
        var x = montMul(one, r2)
        for byte in exp {
            for bit in stride(from: 7, through: 0, by: -1) {
                x = montMul(x, x)
                if (byte >> UInt8(bit)) & 1 == 1 { x = montMul(x, bm) }
            }
        }
        return bytes(montMul(x, one), length: mod.count)
    }
}
