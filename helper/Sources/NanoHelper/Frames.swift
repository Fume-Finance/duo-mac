import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A plain BGRA copy of one captured frame, owned by us (so ScreenCaptureKit's buffers go back to its pool quickly).
final class FrameBuffer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: UnsafeMutableRawPointer

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytesPerRow = ((width * 4) + 63) & ~63
        data = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 64)
        memset(data, 0, bytesPerRow * height)
    }

    deinit { data.deallocate() }

    func copy(from pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let src = CVPixelBufferGetBaseAddress(pb) else { return }
        let srcStride = CVPixelBufferGetBytesPerRow(pb)
        let h = min(height, CVPixelBufferGetHeight(pb))
        let rowBytes = min(width, CVPixelBufferGetWidth(pb)) * 4
        if srcStride == bytesPerRow && h == height {
            memcpy(data, src, bytesPerRow * height)
        } else {
            for y in 0..<h { memcpy(data + y * bytesPerRow, src + y * srcStride, rowBytes) }
        }
    }
}

struct IRect: Equatable {
    var x: Int, y: Int, w: Int, h: Int
    var area: Int { w * h }

    func union(_ o: IRect) -> IRect {
        let x0 = min(x, o.x), y0 = min(y, o.y)
        let x1 = max(x + w, o.x + o.w), y1 = max(y + h, o.y + o.h)
        return IRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }
}

/// Finds the parts of the screen that changed since the last frame the phone received,
/// so typing or moving the pointer only sends a few small JPEG tiles.
enum TileDiff {
    static let tile = 32

    static func diff(_ a: FrameBuffer, _ b: FrameBuffer) -> [IRect] {
        let cols = (a.width + tile - 1) / tile
        let rows = (a.height + tile - 1) / tile
        var dirty = [Bool](repeating: false, count: cols * rows)
        let rowBytes = a.width * 4
        for y in 0..<a.height {
            let pa = a.data + y * a.bytesPerRow
            let pb = b.data + y * b.bytesPerRow
            if memcmp(pa, pb, rowBytes) == 0 { continue }
            let base = (y / tile) * cols
            for tx in 0..<cols where !dirty[base + tx] {
                let x0 = tx * tile
                let w = min(tile, a.width - x0)
                if memcmp(pa + x0 * 4, pb + x0 * 4, w * 4) != 0 { dirty[base + tx] = true }
            }
        }

        // Horizontal runs of dirty tiles, stacked vertically when they line up.
        var done: [IRect] = []
        var open: [Int: IRect] = [:]
        for ty in 0..<rows {
            var next: [Int: IRect] = [:]
            var tx = 0
            while tx < cols {
                if !dirty[ty * cols + tx] { tx += 1; continue }
                let start = tx
                while tx < cols && dirty[ty * cols + tx] { tx += 1 }
                let key = start << 16 | tx
                if var r = open.removeValue(forKey: key) {
                    r.h += 1
                    next[key] = r
                } else {
                    next[key] = IRect(x: start, y: ty, w: tx - start, h: 1)
                }
            }
            done.append(contentsOf: open.values)
            open = next
        }
        done.append(contentsOf: open.values)

        let px = done.map { r in
            IRect(x: r.x * tile, y: r.y * tile,
                  w: min(r.w * tile, a.width - r.x * tile),
                  h: min(r.h * tile, a.height - r.y * tile))
        }
        return merge(px)
    }

    /// Greedily merges nearby rectangles: each JPEG has ~600 bytes of headers, so a few
    /// slightly larger tiles beat many tiny ones.
    static func merge(_ input: [IRect]) -> [IRect] {
        var rs = input
        if rs.count > 48 {
            return [rs.dropFirst().reduce(rs[0]) { $0.union($1) }]
        }
        while rs.count > 1 {
            var best: (i: Int, j: Int, waste: Int)? = nil
            for i in 0..<rs.count {
                for j in (i + 1)..<rs.count {
                    let u = rs[i].union(rs[j])
                    let waste = u.area - rs[i].area - rs[j].area
                    guard waste <= 4096 || waste * 4 <= rs[i].area + rs[j].area else { continue }
                    if best == nil || waste < best!.waste { best = (i, j, waste) }
                }
            }
            guard let b = best else { break }
            rs[b.i] = rs[b.i].union(rs[b.j])
            rs.remove(at: b.j)
        }
        return rs
    }

    /// Splits big rectangles into horizontal bands so they encode (and decode) in parallel.
    static func split(_ rs: [IRect], maxPixels: Int = 320_000) -> [IRect] {
        var out: [IRect] = []
        for r in rs {
            if r.area <= maxPixels {
                out.append(r)
                continue
            }
            let band = max(16, (maxPixels / max(r.w, 1)) / 16 * 16)
            var y = r.y
            while y < r.y + r.h {
                let h = min(band, r.y + r.h - y)
                out.append(IRect(x: r.x, y: y, w: r.w, h: h))
                y += h
            }
        }
        return out
    }
}

enum JPEGEncoder {
    // Device RGB keeps ImageIO from embedding a colour profile (~3 KB per tile).
    // Pixels are already sRGB (we ask ScreenCaptureKit for sRGB), which is what browsers assume for untagged JPEGs.
    static let colorSpace = CGColorSpaceCreateDeviceRGB()
    static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    static func encode(_ f: FrameBuffer, _ r: IRect, quality: Double) -> Data? {
        guard r.w > 0, r.h > 0, r.x >= 0, r.y >= 0, r.x + r.w <= f.width, r.y + r.h <= f.height else { return nil }
        let ptr = UnsafeRawPointer(f.data + r.y * f.bytesPerRow + r.x * 4)
        let size = f.bytesPerRow * (r.h - 1) + r.w * 4
        guard let provider = CGDataProvider(dataInfo: nil, data: ptr, size: size, releaseData: { _, _, _ in }),
              let img = CGImage(width: r.w, height: r.h, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: f.bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo,
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }

    mutating func appendLE(_ v: UInt32) {
        for i in 0..<4 { append(UInt8((v >> (UInt32(i) * 8)) & 0xFF)) }
    }
}
