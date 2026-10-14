import Compression
import Foundation

struct RfbError: LocalizedError {
    let message: String
    /// The user can fix it (sign-in, Screen Sharing settings).
    var userFixable = false
    var errorDescription: String? { message }
}

/// One zlib stream across many chunks (ZRLE keeps a single stream per connection and ends each
/// rectangle with a sync flush). Apple's decoder takes raw DEFLATE, so the 2-byte header is skipped.
final class Inflater {
    private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    private var header = 2
    private let chunk = 1 << 16
    private let buffer: UnsafeMutablePointer<UInt8>

    init() {
        buffer = .allocate(capacity: chunk)
        compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        buffer.deallocate()
    }

    func inflate(_ input: [UInt8]) throws -> [UInt8] {
        var data = input[...]
        if header > 0 {
            let skip = min(header, data.count)
            data = data.dropFirst(skip)
            header -= skip
        }
        var out = [UInt8]()
        try data.withUnsafeBufferPointer { src in
            stream.pointee.src_ptr = src.baseAddress ?? UnsafePointer(buffer)
            stream.pointee.src_size = src.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, 0)
                let produced = chunk - stream.pointee.dst_size
                out.append(contentsOf: UnsafeBufferPointer(start: buffer, count: produced))
                if status == COMPRESSION_STATUS_ERROR { throw RfbError(message: "Corrupt ZRLE data") }
                if status == COMPRESSION_STATUS_END || (stream.pointee.src_size == 0 && produced < chunk) { break }
            }
        }
        return out
    }
}

/// The remote desktop as 0xAARRGGBB pixels, plus the decoders for the encodings mob asks for
/// (ZRLE, CopyRect, Raw). The pixel format is fixed by Rfb.pixelFormat: 32 bpp, depth 24, little
/// endian, red at bit 16, so a pixel arrives as the bytes B, G, R, x.
final class Framebuffer {
    let width: Int
    let height: Int
    var pixels: [UInt32]
    private let inflater = Inflater()

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
    }

    @inline(__always) static func argb(_ b: UInt8, _ g: UInt8, _ r: UInt8) -> UInt32 {
        0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }

    func raw(x: Int, y: Int, w: Int, h: Int, data: [UInt8]) {
        var i = 0
        for row in 0..<h {
            var o = (y + row) * width + x
            for _ in 0..<w {
                pixels[o] = Framebuffer.argb(data[i], data[i + 1], data[i + 2])
                o += 1
                i += 4
            }
        }
    }

    func copyRect(x: Int, y: Int, w: Int, h: Int, srcX: Int, srcY: Int) {
        var tmp = [UInt32](repeating: 0, count: w * h)
        for r in 0..<h { for c in 0..<w { tmp[r * w + c] = pixels[(srcY + r) * width + srcX + c] } }
        for r in 0..<h { for c in 0..<w { pixels[(y + r) * width + x + c] = tmp[r * w + c] } }
    }

    /// ZRLE (RFC 6143 §7.7.6): 64×64 TRLE tiles inside the connection's zlib stream.
    func zrle(x: Int, y: Int, w: Int, h: Int, compressed: [UInt8]) throws {
        try zrleTiles(x: x, y: y, w: w, h: h, data: inflater.inflate(compressed))
    }

    func zrleTiles(x: Int, y: Int, w: Int, h: Int, data: [UInt8]) throws {
        var r = TileReader(data: data)
        var ty = 0
        while ty < h {
            let th = min(64, h - ty)
            var tx = 0
            while tx < w {
                try tile(x: x + tx, y: y + ty, w: min(64, w - tx), h: th, &r)
                tx += 64
            }
            ty += 64
        }
    }

    private func tile(x: Int, y: Int, w: Int, h: Int, _ r: inout TileReader) throws {
        let sub = try r.u8()
        switch sub {
        case 0:
            for row in 0..<h { for c in 0..<w { pixels[(y + row) * width + x + c] = try r.cpixel() } }
        case 1:
            let color = try r.cpixel()
            for row in 0..<h { for c in 0..<w { pixels[(y + row) * width + x + c] = color } }
        case 2...16:
            var palette = [UInt32]()
            for _ in 0..<sub { palette.append(try r.cpixel()) }
            let bits = sub == 2 ? 1 : sub <= 4 ? 2 : 4
            let mask = (1 << bits) - 1
            for row in 0..<h {
                var bit = 0
                var byte = 0
                for c in 0..<w {
                    if bit == 0 {
                        byte = try r.u8()
                        bit = 8
                    }
                    bit -= bits
                    let idx = (byte >> bit) & mask
                    pixels[(y + row) * width + x + c] = idx < palette.count ? palette[idx] : palette[0]
                }
            }
        case 128:
            try runs(x: x, y: y, w: w, h: h) { (try r.cpixel(), try r.runLength()) }
        case 130...255:
            var palette = [UInt32]()
            for _ in 0..<(sub - 128) { palette.append(try r.cpixel()) }
            try runs(x: x, y: y, w: w, h: h) {
                let b = try r.u8()
                let color = (b & 0x7F) < palette.count ? palette[b & 0x7F] : palette[0]
                return (color, b & 0x80 != 0 ? try r.runLength() : 1)
            }
        default:
            throw RfbError(message: "ZRLE subencoding \(sub) is not supported")
        }
    }

    /// Fills a tile in row order from (colour, run length) pairs.
    private func runs(x: Int, y: Int, w: Int, h: Int, _ next: () throws -> (UInt32, Int)) throws {
        var i = 0
        let total = w * h
        while i < total {
            let (color, len) = try next()
            for _ in 0..<min(len, total - i) {
                pixels[(y + i / w) * width + x + i % w] = color
                i += 1
            }
        }
    }

    private struct TileReader {
        let data: [UInt8]
        var o = 0

        mutating func u8() throws -> Int {
            guard o < data.count else { throw RfbError(message: "ZRLE data ended early") }
            defer { o += 1 }
            return Int(data[o])
        }

        /// A compressed pixel is the three low bytes: B, G, R.
        mutating func cpixel() throws -> UInt32 {
            guard o + 3 <= data.count else { throw RfbError(message: "ZRLE data ended early") }
            defer { o += 3 }
            return Framebuffer.argb(data[o], data[o + 1], data[o + 2])
        }

        mutating func runLength() throws -> Int {
            var len = 1
            var more: Int
            repeat {
                more = try u8()
                len += more
            } while more == 255
            return len
        }
    }
}
