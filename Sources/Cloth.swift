import Foundation
import simd

// A sheet of paper as cloth: XPBD with substeps (as in Ten Minute Physics), a floor with Coulomb friction,
// air drag across the sheet, self collisions through a spatial hash.
// Coordinates are screen points, x right, y up, z toward the viewer.

struct Con {
    var a: Int32
    var b: Int32
    var rest: Float
    var compliance: Float
}

struct ClothParams {
    var gravity: Float = 5000
    var substeps = 10
    var shearCompliance: Float = 2e-7
    var bendCompliance: Float = 3e-7     // bending along the grid lines; negative turns it off
    var farBendCompliance: Float = -1   // bending across 4 nodes, a negative value turns it off
    var airDamping: Float = 1.3
    var groundStatic: Float = 2
    var groundKinetic: Float = 1.3
    var selfFriction: Float = 0.3
    var normalDrag: Float = 0       // air slows motion across the sheet, so paper glides
    var hingeCompliance: Float = -1  // bending at every crease between triangles, the same in every direction; negative turns it off
    var layerScale: Float = -1       // how close two layers of a folded sheet may lie, in grid spacings; negative keeps the full thickness
    var columns = 44

    // Paper is light and springy: it bends smoothly instead of crumpling, slides on the desk and floats as it falls.
    // Hinges at every crease make it resist bending the same way in every direction, so a lifted corner rolls into
    // a cone-shaped curl instead of folding along the diagonal like fabric, and folded layers lie thin against each other.
    static var paper: ClothParams {
        var p = ClothParams()
        p.hingeCompliance = 1e-6
        p.layerScale = 0.3
        p.gravity = 2600
        p.bendCompliance = 4e-8
        p.farBendCompliance = 1.5e-7
        p.airDamping = 1.6
        p.normalDrag = 15
        p.groundStatic = 0.9
        p.groundKinetic = 0.55
        p.selfFriction = 0.2
        p.columns = 34
        return p
    }
}

struct Camera {
    var size: SIMD2<Float>
    var D: Float { max(size.x, size.y) * 1.15 }
    var center: SIMD2<Float> { size * 0.5 }

    func project(_ p: SIMD3<Float>) -> SIMD2<Float> {
        let w = (D - p.z) / D
        return center + (SIMD2(p.x, p.y) - center) / w
    }

    func unproject(_ s: SIMD2<Float>, z: Float) -> SIMD3<Float> {
        let w = (D - z) / D
        let xy = center + (s - center) * w
        return SIMD3(xy.x, xy.y, z)
    }
}

final class Cloth {
    let nx: Int, ny: Int, count: Int
    let width: Float, height: Float, spacing: Float, thickness: Float
    var params: ClothParams

    let pos: UnsafeMutablePointer<SIMD3<Float>>
    let prev: UnsafeMutablePointer<SIMD3<Float>>
    let vel: UnsafeMutablePointer<SIMD3<Float>>
    let rest: UnsafeMutablePointer<SIMD3<Float>>
    let nrm: UnsafeMutablePointer<SIMD3<Float>>
    let proj: UnsafeMutablePointer<SIMD2<Float>>
    let invMass: UnsafeMutablePointer<Float>
    private var cons: [Con] = []
    // A crease between two triangles: shared edge a-b, opposite corners c and d,
    // with the weights of the discrete curvature (isometric bending, Bergou et al. 2006).
    private struct Hinge {
        var v: SIMD4<Int32>
        var k: SIMD4<Float>
    }
    private var hinges: [Hinge] = []
    private(set) var indices: [UInt32] = []
    private(set) var uvs: [SIMD2<Float>] = []
    private let hash: SpatialHash

    var bboxMin = SIMD2<Float>(repeating: 0)
    var bboxMax = SIMD2<Float>(repeating: 0)
    private(set) var maxSpeed: Float = 0

    private var grabbedIds: [Int] = []
    private var grabOffsets: [SIMD3<Float>] = []
    private var grabPos = SIMD3<Float>(repeating: 0)
    private var tetherRest: [Float] = []
    var grabTarget = SIMD3<Float>(repeating: 0)
    // the height the sheet rests at: sheets in a stack lie on each other
    var floorZ: Float = 0
    var isGrabbing: Bool { !grabbedIds.isEmpty }

    init(width: Float, height: Float, params: ClothParams) {
        self.params = params
        let columns = params.columns
        nx = columns
        spacing = width / Float(columns - 1)
        ny = max(3, Int((height / spacing).rounded()) + 1)
        count = nx * ny
        self.width = width
        self.height = spacing * Float(ny - 1)
        thickness = spacing * 1.1

        pos = .allocate(capacity: count)
        prev = .allocate(capacity: count)
        vel = .allocate(capacity: count)
        rest = .allocate(capacity: count)
        nrm = .allocate(capacity: count)
        proj = .allocate(capacity: count)
        invMass = .allocate(capacity: count)
        hash = SpatialHash(spacing: thickness, maxObjects: count)

        for j in 0..<ny {
            for i in 0..<nx {
                let k = idx(i, j)
                rest[k] = SIMD3(Float(i) * spacing - self.width / 2, Float(j) * spacing - self.height / 2, 0)
                pos[k] = rest[k]
                prev[k] = rest[k]
                vel[k] = .zero
                nrm[k] = SIMD3(0, 0, 1)
                invMass[k] = 1
                uvs.append(SIMD2(Float(i) / Float(nx - 1), 1 - Float(j) / Float(ny - 1)))
            }
        }
        for j in 0..<(ny - 1) {
            for i in 0..<(nx - 1) {
                let a = UInt32(idx(i, j)), b = UInt32(idx(i + 1, j))
                let c = UInt32(idx(i, j + 1)), d = UInt32(idx(i + 1, j + 1))
                if (i + j) % 2 == 0 {
                    indices += [a, b, d, a, d, c]
                } else {
                    indices += [a, b, c, b, d, c]
                }
            }
        }
        let p = params
        for j in 0..<ny {
            for i in 0..<nx {
                if i + 1 < nx { addCon(idx(i, j), idx(i + 1, j), 0) }
                if j + 1 < ny { addCon(idx(i, j), idx(i, j + 1), 0) }
                if i + 1 < nx && j + 1 < ny {
                    addCon(idx(i, j), idx(i + 1, j + 1), p.shearCompliance)
                    addCon(idx(i + 1, j), idx(i, j + 1), p.shearCompliance)
                }
                if p.bendCompliance >= 0 {
                    if i + 2 < nx { addCon(idx(i, j), idx(i + 2, j), p.bendCompliance) }
                    if j + 2 < ny { addCon(idx(i, j), idx(i, j + 2), p.bendCompliance) }
                }
                if p.farBendCompliance >= 0 {
                    if i + 4 < nx { addCon(idx(i, j), idx(i + 4, j), p.farBendCompliance) }
                    if j + 4 < ny { addCon(idx(i, j), idx(i, j + 4), p.farBendCompliance) }
                }
            }
        }
        if p.hingeCompliance >= 0 { buildHinges() }
    }

    deinit {
        pos.deallocate(); prev.deallocate(); vel.deallocate(); rest.deallocate()
        nrm.deallocate(); proj.deallocate(); invMass.deallocate()
    }

    @inline(__always) func idx(_ i: Int, _ j: Int) -> Int { j * nx + i }

    // Every edge shared by two triangles becomes a hinge. Its weights come from the cotangents of the rest shape,
    // so a flat sheet has zero bend and any bend costs the same whatever its direction.
    private func buildHinges() {
        func cot(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> Float { simd_dot(u, v) / max(1e-9, simd_length(simd_cross(u, v))) }
        var opposite: [UInt64: Int] = [:]
        var t = 0
        while t < indices.count {
            let tri = [Int(indices[t]), Int(indices[t + 1]), Int(indices[t + 2])]
            t += 3
            for e in 0..<3 {
                let a = tri[e], b = tri[(e + 1) % 3], o = tri[(e + 2) % 3]
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                guard let o2 = opposite[key] else { opposite[key] = o; continue }
                let x0 = rest[a], x1 = rest[b], x2 = rest[o2], x3 = rest[o]
                let e0 = x1 - x0, e1 = x2 - x0, e2 = x3 - x0, e3 = x2 - x1, e4 = x3 - x1
                let c01 = cot(e0, e1), c02 = cot(e0, e2), c03 = cot(-e0, e3), c04 = cot(-e0, e4)
                hinges.append(Hinge(v: SIMD4(Int32(a), Int32(b), Int32(o2), Int32(o)),
                                    k: SIMD4(c03 + c04, c01 + c02, -c01 - c03, -c02 - c04)))
            }
        }
    }

    private func addCon(_ a: Int, _ b: Int, _ c: Float) {
        cons.append(Con(a: Int32(a), b: Int32(b), rest: simd_length(rest[a] - rest[b]), compliance: c))
    }

    // MARK: layout

    func layout(center: SIMD2<Float>, angle: Float, drop: Float) {
        endGrab()
        let ca = cos(angle), sa = sin(angle)
        for j in 0..<ny {
            for i in 0..<nx {
                let k = idx(i, j)
                let r = rest[k]
                let u = Float(i) / Float(nx - 1)
                let z = floorZ + (drop > 0 ? drop * (0.55 + 0.45 * u) + Float.random(in: -1.5...1.5) : 0)
                pos[k] = SIMD3(center.x + r.x * ca - r.y * sa, center.y + r.x * sa + r.y * ca, z)
                prev[k] = pos[k]
                vel[k] = .zero
            }
        }
        maxSpeed = 1000
    }

    func pose() -> (center: SIMD2<Float>, angle: Float) {
        var c = SIMD2<Float>(repeating: 0)
        for i in 0..<count { c += SIMD2(pos[i].x, pos[i].y) }
        c /= Float(count)
        let j = ny / 2
        let a = pos[idx(0, j)], b = pos[idx(nx - 1, j)]
        return (c, atan2(b.y - a.y, b.x - a.x))
    }

    func rotate(by angle: Float) {
        let c = pose().center
        let ca = cos(angle), sa = sin(angle)
        func rot(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let d = SIMD2(p.x, p.y) - c
            return SIMD3(c.x + d.x * ca - d.y * sa, c.y + d.x * sa + d.y * ca, p.z)
        }
        for i in 0..<count {
            pos[i] = rot(pos[i])
            prev[i] = rot(prev[i])
        }
        if isGrabbing {
            grabPos = rot(grabPos)
            grabTarget = rot(grabTarget)
        }
    }

    // MARK: grabbing

    func beginGrab(vertex v: Int, target: SIMD3<Float>) {
        endGrab()
        let vi = v % nx, vj = v / nx
        let center = pos[v]
        for j in max(0, vj - 1)...min(ny - 1, vj + 1) {
            for i in max(0, vi - 1)...min(nx - 1, vi + 1) {
                let k = idx(i, j)
                grabbedIds.append(k)
                var o = pos[k] - center
                o.z = 0
                grabOffsets.append(o)
                invMass[k] = 0
            }
        }
        grabPos = center
        grabTarget = target
        // long-range tethers: no point gets further from the hand than along the cloth at rest
        tetherRest = (0..<count).map { simd_length(rest[$0] - rest[v]) * 1.01 }
        maxSpeed = 1000
    }

    func endGrab() {
        let cap: Float = 1400
        for k in grabbedIds {
            invMass[k] = 1
            let s = simd_length(vel[k])
            if s > cap { vel[k] *= cap / s }
        }
        grabbedIds.removeAll()
        grabOffsets.removeAll()
    }

    // MARK: simulation step

    func step(dt frameDt: Float) {
        let n = params.substeps
        let sdt = frameDt / Float(n)
        let reach = spacing * 1.1
        let maxVel = 0.2 * reach / sdt
        let travel = min(max(maxSpeed * frameDt * 1.5, thickness), reach * 4)
        hash.create(pos, count)
        hash.queryAll(pos, count, maxDist: travel)

        for _ in 0..<n {
            integrate(sdt, maxVel)
            moveGrabbed(sdt)
            solveConstraints(sdt)
            solveHinges(sdt)
            solveTethers()
            solveSelfCollisions()
            solveSelfCollisions()
            solveGround()
            let inv = 1 / sdt
            for i in 0..<count { vel[i] = (pos[i] - prev[i]) * inv }
        }
        var m: Float = 0
        for i in 0..<count where invMass[i] > 0 { m = max(m, simd_length_squared(vel[i])) }
        maxSpeed = m.squareRoot()
        if !maxSpeed.isFinite {
            // just in case: if the solver blows up, lay the sheet down again
            let c = SIMD2<Float>(prev[count / 2].x, prev[count / 2].y)
            layout(center: c.x.isFinite && c.y.isFinite ? c : SIMD2(width, height), angle: 0, drop: 60)
        }
    }

    private func solveTethers() {
        guard isGrabbing, tetherRest.count == count else { return }
        let g = grabPos
        for i in 0..<count {
            if invMass[i] == 0 { continue }
            let d = pos[i] - g
            let l = simd_length(d)
            let m = tetherRest[i]
            if l > m { pos[i] = g + d * (m / l) }
        }
    }

    private func integrate(_ sdt: Float, _ maxVel: Float) {
        let g = params.gravity * sdt
        let damp = max(0, 1 - params.airDamping * sdt)
        let mv2 = maxVel * maxVel
        let nd = min(1, params.normalDrag * sdt)
        for i in 0..<count {
            if invMass[i] == 0 { continue }
            var v = vel[i]
            v.z -= g
            v *= damp
            if nd > 0 {
                let n = nrm[i]
                v -= n * (simd_dot(v, n) * nd)
            }
            let s2 = simd_length_squared(v)
            if s2 > mv2 { v *= maxVel / s2.squareRoot() }
            vel[i] = v
            prev[i] = pos[i]
            pos[i] += v * sdt
        }
    }

    private func moveGrabbed(_ sdt: Float) {
        guard isGrabbing else { return }
        var d = (grabTarget - grabPos) * min(1, sdt * 30)
        let maxStep = 0.3 * spacing * 1.1
        let l = simd_length(d)
        if l > maxStep { d *= maxStep / l }
        grabPos += d
        for (n, k) in grabbedIds.enumerated() {
            prev[k] = pos[k]
            pos[k] = grabPos + grabOffsets[n]
        }
    }

    private func solveConstraints(_ sdt: Float) {
        let inv = 1 / (sdt * sdt)
        cons.withUnsafeBufferPointer { cb in
            for c in cb {
                let a = Int(c.a), b = Int(c.b)
                let wa = invMass[a], wb = invMass[b]
                let w = wa + wb
                if w == 0 { continue }
                let d = pos[b] - pos[a]
                let len = simd_length(d)
                if len < 1e-6 { continue }
                let s = -(len - c.rest) / (w + c.compliance * inv)
                let nd = d / len
                pos[a] -= nd * (s * wa)
                pos[b] += nd * (s * wb)
            }
        }
    }

    // Bending: the curvature vector of each hinge, measured along the crease normal, is pushed back to zero.
    // It only acts across the sheet, so it never fights the stretch and shear links or the desk's friction.
    private func solveHinges(_ sdt: Float) {
        guard !hinges.isEmpty else { return }
        let alpha = params.hingeCompliance / (sdt * sdt)
        hinges.withUnsafeBufferPointer { hb in
            for h in hb {
                let a = Int(h.v.x), b = Int(h.v.y), c = Int(h.v.z), d = Int(h.v.w)
                let x0 = pos[a], x1 = pos[b], x2 = pos[c], x3 = pos[d]
                var n = simd_cross(x1 - x0, x2 - x0) + simd_cross(x3 - x0, x1 - x0)
                let ln = simd_length(n)
                if ln < 1e-9 { continue }
                n /= ln
                let k = h.k
                let bend = simd_dot(x0 * k.x + x1 * k.y + x2 * k.z + x3 * k.w, n)
                let wa = invMass[a], wb = invMass[b], wc = invMass[c], wd = invMass[d]
                let den = wa * k.x * k.x + wb * k.y * k.y + wc * k.z * k.z + wd * k.w * k.w + alpha
                if den < 1e-12 { continue }
                let l = -bend / den
                pos[a] += n * (l * wa * k.x)
                pos[b] += n * (l * wb * k.y)
                pos[c] += n * (l * wc * k.z)
                pos[d] += n * (l * wd * k.w)
            }
        }
    }

    // Points held by the mouse also collide: they have infinite mass, only the neighbour moves.
    private func solveSelfCollisions() {
        let t = thickness, t2 = t * t
        let layer = params.layerScale * spacing
        let fr = params.selfFriction
        for i in 0..<count {
            let first = Int(hash.firstAdj[i]), last = Int(hash.firstAdj[i + 1])
            if first == last { continue }
            let wi = invMass[i]
            for k in first..<last {
                let j = Int(hash.adj[k])
                let wj = invMass[j]
                let w = wi + wj
                if w == 0 { continue }
                var d = pos[j] - pos[i]
                let dist2 = simd_length_squared(d)
                if dist2 > t2 || dist2 == 0 { continue }
                let restDist2 = simd_length_squared(rest[i] - rest[j])
                if dist2 > restDist2 { continue }
                // close neighbours keep their rest spacing (that also stops the grid bunching up);
                // points from separate layers of a fold only keep the thin layer gap
                var minDist = restDist2 < t2 ? restDist2.squareRoot() : (layer > 0 ? layer : t)
                minDist = min(minDist, t)
                if dist2 >= minDist * minDist { continue }
                let dist = dist2.squareRoot()
                d *= (minDist - dist) / (dist * w)
                pos[i] -= d * wi
                pos[j] += d * wj
                let v0 = pos[i] - prev[i], v1 = pos[j] - prev[j]
                let avg = (v0 * wj + v1 * wi) / w
                pos[i] += (avg - v0) * (fr * wi / w * 2)
                pos[j] += (avg - v1) * (fr * wj / w * 2)
            }
        }
    }

    private func solveGround() {
        let ms = params.groundStatic, mk = params.groundKinetic
        for i in 0..<count {
            if invMass[i] == 0 { continue }
            var p = pos[i]
            let h = floorZ
            if p.z >= h { continue }
            let pen = h - p.z
            p.z = h
            let q = prev[i]
            let dx = p.x - q.x, dy = p.y - q.y
            let l = (dx * dx + dy * dy).squareRoot()
            if l < ms * pen {
                p.x = q.x
                p.y = q.y
            } else if l > 0 {
                let k = min(mk * pen / l, 1)
                p.x -= dx * k
                p.y -= dy * k
            }
            pos[i] = p
        }
    }

    // MARK: derived data for rendering and the mouse

    func updateDerived(_ cam: Camera) {
        for i in 0..<count { nrm[i] = .zero }
        indices.withUnsafeBufferPointer { ib in
            var t = 0
            while t < ib.count {
                let a = Int(ib[t]), b = Int(ib[t + 1]), c = Int(ib[t + 2])
                t += 3
                let n = simd_cross(pos[b] - pos[a], pos[c] - pos[a])
                nrm[a] += n; nrm[b] += n; nrm[c] += n
            }
        }
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0..<count {
            let l = simd_length(nrm[i])
            nrm[i] = l > 0 ? nrm[i] / l : SIMD3(0, 0, 1)
            let s = cam.project(pos[i])
            proj[i] = s
            lo = simd_min(lo, s)
            hi = simd_max(hi, s)
        }
        bboxMin = lo
        bboxMax = hi
    }

    // The sheet point (texture uv) under a screen point, on the topmost triangle.
    func pickUV(_ s: SIMD2<Float>) -> SIMD2<Float>? {
        if s.x < bboxMin.x || s.y < bboxMin.y || s.x > bboxMax.x || s.y > bboxMax.y { return nil }
        var bestZ = -Float.greatestFiniteMagnitude
        var best: SIMD2<Float>?
        var t = 0
        while t < indices.count {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            t += 3
            let pa = proj[a], v0 = proj[b] - pa, v1 = proj[c] - pa, v2 = s - pa
            let den = v0.x * v1.y - v1.x * v0.y
            if abs(den) < 1e-6 { continue }
            let u = (v2.x * v1.y - v1.x * v2.y) / den
            let v = (v0.x * v2.y - v2.x * v0.y) / den
            if u < 0 || v < 0 || u + v > 1 { continue }
            let w = 1 - u - v
            let z = pos[a].z * w + pos[b].z * u + pos[c].z * v
            if z > bestZ {
                bestZ = z
                best = uvs[a] * w + uvs[b] * u + uvs[c] * v
            }
        }
        return best
    }

    // The topmost triangle under a screen point. Returns its nearest vertex and height.
    func pick(_ s: SIMD2<Float>, needVertex: Bool) -> (vertex: Int, z: Float)? {
        if s.x < bboxMin.x || s.y < bboxMin.y || s.x > bboxMax.x || s.y > bboxMax.y { return nil }
        var bestZ = -Float.greatestFiniteMagnitude
        var bestV = -1
        indices.withUnsafeBufferPointer { ib in
            var t = 0
            while t < ib.count {
                let a = Int(ib[t]), b = Int(ib[t + 1]), c = Int(ib[t + 2])
                t += 3
                let pa = proj[a], pb = proj[b], pc = proj[c]
                if s.x < min(pa.x, pb.x, pc.x) || s.x > max(pa.x, pb.x, pc.x) { continue }
                if s.y < min(pa.y, pb.y, pc.y) || s.y > max(pa.y, pb.y, pc.y) { continue }
                let v0 = pb - pa, v1 = pc - pa, v2 = s - pa
                let den = v0.x * v1.y - v1.x * v0.y
                if abs(den) < 1e-6 { continue }
                let u = (v2.x * v1.y - v1.x * v2.y) / den
                let v = (v0.x * v2.y - v2.x * v0.y) / den
                if u < 0 || v < 0 || u + v > 1 { continue }
                let w = 1 - u - v
                let z = pos[a].z * w + pos[b].z * u + pos[c].z * v
                if z > bestZ {
                    bestZ = z
                    bestV = (w >= u && w >= v) ? a : (u >= v ? b : c)
                    if !needVertex { return }
                }
            }
        }
        return bestV >= 0 ? (bestV, bestZ) : nil
    }
}
