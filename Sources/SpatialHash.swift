import simd

// Spatial hash for cloth self collisions (a port of Hash from Ten Minute Physics #11/#15).
final class SpatialHash {
    let spacing: Float
    let tableSize: Int
    let maxObjects: Int
    private let cellStart: UnsafeMutablePointer<Int32>
    private let cellEntries: UnsafeMutablePointer<Int32>
    private let queryIds: UnsafeMutablePointer<Int32>
    private var querySize = 0
    let firstAdj: UnsafeMutablePointer<Int32>
    private(set) var adj: UnsafeMutablePointer<Int32>
    private var adjCapacity: Int

    init(spacing: Float, maxObjects: Int) {
        self.spacing = spacing
        self.maxObjects = maxObjects
        tableSize = 2 * maxObjects
        cellStart = .allocate(capacity: tableSize + 1)
        cellEntries = .allocate(capacity: maxObjects)
        queryIds = .allocate(capacity: maxObjects)
        firstAdj = .allocate(capacity: maxObjects + 1)
        adjCapacity = 16 * maxObjects
        adj = .allocate(capacity: adjCapacity)
        firstAdj.initialize(repeating: 0, count: maxObjects + 1)
    }

    deinit {
        cellStart.deallocate(); cellEntries.deallocate(); queryIds.deallocate()
        firstAdj.deallocate(); adj.deallocate()
    }

    @inline(__always) private func coord(_ c: Float) -> Int32 { Int32(floor(c / spacing)) }

    @inline(__always) private func hashCoords(_ x: Int32, _ y: Int32, _ z: Int32) -> Int {
        let h = (x &* 92837111) ^ (y &* 689287499) ^ (z &* 283923481)
        return Int(h.magnitude) % tableSize
    }

    @inline(__always) private func hashPos(_ p: SIMD3<Float>) -> Int {
        hashCoords(coord(p.x), coord(p.y), coord(p.z))
    }

    func create(_ pos: UnsafeMutablePointer<SIMD3<Float>>, _ n: Int) {
        cellStart.initialize(repeating: 0, count: tableSize + 1)
        for i in 0..<n { cellStart[hashPos(pos[i])] += 1 }
        var start: Int32 = 0
        for i in 0..<tableSize {
            start += cellStart[i]
            cellStart[i] = start
        }
        cellStart[tableSize] = start
        for i in 0..<n {
            let h = hashPos(pos[i])
            cellStart[h] -= 1
            cellEntries[Int(cellStart[h])] = Int32(i)
        }
    }

    private func query(_ p: SIMD3<Float>, _ maxDist: Float) {
        let x0 = coord(p.x - maxDist), y0 = coord(p.y - maxDist), z0 = coord(p.z - maxDist)
        let x1 = coord(p.x + maxDist), y1 = coord(p.y + maxDist), z1 = coord(p.z + maxDist)
        querySize = 0
        for xi in x0...x1 {
            for yi in y0...y1 {
                for zi in z0...z1 {
                    let h = hashCoords(xi, yi, zi)
                    let s = Int(cellStart[h]), e = Int(cellStart[h + 1])
                    var i = s
                    while i < e && querySize < maxObjects {
                        queryIds[querySize] = cellEntries[i]
                        querySize += 1
                        i += 1
                    }
                }
            }
        }
    }

    // For each particle, the list of neighbours closer than maxDist (only j < i, each pair once).
    func queryAll(_ pos: UnsafeMutablePointer<SIMD3<Float>>, _ n: Int, maxDist: Float) {
        var num = 0
        let md2 = maxDist * maxDist
        for i in 0..<n {
            firstAdj[i] = Int32(num)
            query(pos[i], maxDist)
            for q in 0..<querySize {
                let j = Int(queryIds[q])
                if j >= i { continue }
                if simd_length_squared(pos[j] - pos[i]) > md2 { continue }
                if num >= adjCapacity {
                    let bigger = UnsafeMutablePointer<Int32>.allocate(capacity: adjCapacity * 2)
                    bigger.update(from: adj, count: adjCapacity)
                    adj.deallocate()
                    adj = bigger
                    adjCapacity *= 2
                }
                adj[num] = Int32(j)
                num += 1
            }
        }
        firstAdj[n] = Int32(num)
    }
}
