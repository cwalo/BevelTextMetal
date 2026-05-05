import Foundation

/// 8-point sequential signed Euclidean distance transform (8SSEDT).
///
/// Each cell propagates a 2D offset vector to its nearest seed through two
/// 8-direction sweeps. The resulting distance field has none of the
/// `sqrt(integer)` quantization rings that an exact EDT (e.g. Meijster) shows
/// when interpolated, which is what produced the visible scalloping in the
/// rim/shadow when the layered shader smoothstepped across them.
enum SDF8SSEDT {

    /// Computes a signed pixel-distance field. `inside[i] == true` marks a
    /// foreground pixel. Output is positive inside the foreground and negative
    /// outside, in pixel units.
    static func compute(inside: [Bool], w: Int, h: Int) -> [Float] {
        let outsideOffsets = sweep(seeded(inside: inside, foreground: false, w: w, h: h), w: w, h: h)
        let insideOffsets  = sweep(seeded(inside: inside, foreground: true,  w: w, h: h), w: w, h: h)

        var sdf = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            // outDist = distance to nearest *outside* pixel — positive depth
            //           inward for foreground cells, 0 for background cells.
            // inDist  = distance to nearest *inside*  pixel — 0 for foreground,
            //           positive distance for background cells.
            let outDist = sqrt(Float(outsideOffsets[i].sq))
            let inDist  = sqrt(Float(insideOffsets[i].sq))
            sdf[i] = outDist - inDist
        }
        return sdf
    }

    private struct Offset {
        var dx: Int16
        var dy: Int16
        @inline(__always) var sq: Int32 { Int32(dx) * Int32(dx) + Int32(dy) * Int32(dy) }
    }
    private static let inf: Int16 = 16384

    private static func seeded(inside: [Bool], foreground: Bool, w: Int, h: Int) -> [Offset] {
        let zero = Offset(dx: 0, dy: 0)
        let far  = Offset(dx: inf, dy: inf)
        var grid = [Offset](repeating: far, count: w * h)
        for i in 0..<(w * h) where inside[i] == foreground {
            grid[i] = zero
        }
        return grid
    }

    private static func sweep(_ initial: [Offset], w: Int, h: Int) -> [Offset] {
        var g = initial

        @inline(__always) func compare(_ x: Int, _ y: Int, dx: Int, dy: Int) {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, nx < w, ny >= 0, ny < h else { return }
            let neighbor = g[ny * w + nx]
            // Offset stored at a cell points "from seed to cell"; shifting that
            // by (-dx, -dy) gives the candidate offset at the current cell.
            let candidate = Offset(dx: neighbor.dx - Int16(dx),
                                   dy: neighbor.dy - Int16(dy))
            if candidate.sq < g[y * w + x].sq { g[y * w + x] = candidate }
        }

        for y in 0..<h {
            for x in 0..<w {
                compare(x, y, dx: -1, dy:  0)
                compare(x, y, dx: -1, dy: -1)
                compare(x, y, dx:  0, dy: -1)
                compare(x, y, dx:  1, dy: -1)
            }
            for x in stride(from: w - 1, through: 0, by: -1) {
                compare(x, y, dx: 1, dy: 0)
            }
        }

        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                compare(x, y, dx:  1, dy:  0)
                compare(x, y, dx:  1, dy:  1)
                compare(x, y, dx:  0, dy:  1)
                compare(x, y, dx: -1, dy:  1)
            }
            for x in 0..<w {
                compare(x, y, dx: -1, dy: 0)
            }
        }
        return g
    }
}
