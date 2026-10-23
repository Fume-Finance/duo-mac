import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR codes for the pairing link: as an image for the window and as text for the terminal.
enum QR {
    /// Module matrix (true = dark), cropped to the code itself (no quiet zone), row 0 at the top.
    static func modules(_ text: String) -> [[Bool]] {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let img = f.outputImage else { return [] }
        let w = Int(img.extent.width), h = Int(img.extent.height)
        guard w > 0, h > 0 else { return [] }
        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        var px = [UInt8](repeating: 255, count: w * h * 4)
        ctx.render(img, toBitmap: &px, rowBytes: w * 4, bounds: img.extent, format: .RGBA8,
                   colorSpace: CGColorSpaceCreateDeviceRGB())
        var m = (0..<h).map { y in (0..<w).map { x in px[(y * w + x) * 4] < 128 } }

        // Crop the quiet zone CoreImage adds.
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where m[y][x] {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX, maxY >= minY else { return [] }
        m = (minY...maxY).map { y in Array(m[y][minX...maxX]) }

        // Make sure the finder patterns sit top-left, top-right and bottom-left
        // (CoreImage's bitmap origin may be bottom-left).
        let n = m.count
        func finder(_ r: Int, _ c: Int) -> Bool {
            guard r >= 0, c >= 0, r + 7 <= n, c + 7 <= n else { return false }
            for i in 0..<7 {
                if !m[r][c + i] || !m[r + 6][c + i] || !m[r + i][c] || !m[r + i][c + 6] { return false }
            }
            for i in 1..<6 where m[r + 1][c + i] { return false }
            return true
        }
        if !(finder(0, 0) && finder(0, n - 7) && finder(n - 7, 0)) && finder(n - 7, n - 7) {
            m.reverse()
        }
        return m
    }

    static func cgImage(_ m: [[Bool]], scale: Int, quiet: Int = 3) -> CGImage? {
        let n = m.count
        guard n > 0 else { return nil }
        let size = (n + quiet * 2) * scale
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(gray: 0, alpha: 1)
        for (y, row) in m.enumerated() {
            for (x, on) in row.enumerated() where on {
                // CGContext origin is bottom-left: flip so row 0 ends up on top.
                ctx.fill(CGRect(x: (x + quiet) * scale, y: size - (y + quiet + 1) * scale, width: scale, height: scale))
            }
        }
        return ctx.makeImage()
    }

    static func image(_ text: String) -> NSImage? {
        let m = modules(text)
        guard let cg = cgImage(m, scale: 8) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Two modules per character cell with explicit colours, so it scans on light and dark terminals.
    static func terminal(_ m: [[Bool]], quiet: Int = 2) -> String {
        let n = m.count
        guard n > 0 else { return "" }
        let size = n + quiet * 2
        func dark(_ y: Int, _ x: Int) -> Bool {
            let yy = y - quiet, xx = x - quiet
            guard yy >= 0, yy < n, xx >= 0, xx < n else { return false }
            return m[yy][xx]
        }
        var out = ""
        var y = 0
        while y < size {
            out += "  "
            for x in 0..<size {
                let top = dark(y, x), bottom = y + 1 < size ? dark(y + 1, x) : false
                out += "\u{1B}[\(top ? 30 : 97);\(bottom ? 40 : 107)m▀"
            }
            out += "\u{1B}[0m\n"
            y += 2
        }
        return out
    }
}
