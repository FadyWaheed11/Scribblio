import MetalKit
import simd

struct GPUVertex {
    var pos: SIMD4<Float>
    var nrm: SIMD4<Float>
}

struct Uniforms {
    var lightDir = SIMD4<Float>(0, 0, 1, 0)
    var floorRect = SIMD4<Float>(0, 0, 0, 0)
    var viewSize = SIMD2<Float>(0, 0)
    var lightK = SIMD2<Float>(0, 0)
    var shadowMapSize = SIMD2<Float>(0, 0)
    var camD: Float = 1000
    var floorZ: Float = -4
    var shadowStrength: Float = 0.5
}

// GPU buffers of one sheet: a vertex buffer per frame in flight, shared indices and uvs.
final class SheetMesh {
    let ibuf, uvbuf: MTLBuffer
    let vbufs: [MTLBuffer]
    let indexCount: Int
    var vIndex = 0

    init(device: MTLDevice, cloth: Cloth) {
        indexCount = cloth.indices.count
        ibuf = cloth.indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        uvbuf = cloth.uvs.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        vbufs = (0..<3).map { _ in device.makeBuffer(length: MemoryLayout<GPUVertex>.stride * cloth.count, options: .storageModeShared)! }
    }
}

struct Sheet {
    let cloth: Cloth
    let mesh: SheetMesh
    let texture: MTLTexture
}

final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let colorFormat: MTLPixelFormat
    private let depthFormat: MTLPixelFormat
    private let sampleCount: Int
    private let sheetPSO, floorPSO, shadowPSO: MTLRenderPipelineState
    private let depthLess, depthAlways: MTLDepthStencilState
    private let texSampler, nearestSampler: MTLSamplerState
    private var shadowTex: MTLTexture?
    private var shadowDepth: MTLTexture?
    private let inflight = DispatchSemaphore(value: 3)

    // the shading light is lower and the shadow light higher, so shadows stay short and folds read well
    let shadeLight = simd_normalize(SIMD3<Float>(-0.5, 0.58, 0.64))
    let shadowLight = simd_normalize(SIMD3<Float>(-0.3, 0.38, 0.87))

    init(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat, sampleCount: Int) throws {
        guard let queue = device.makeCommandQueue() else {
            throw NSError(domain: "Scribblio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is not available"])
        }
        self.device = device
        self.queue = queue
        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
        self.sampleCount = sampleCount
        let lib = try device.makeLibrary(source: shaderSource, options: nil)

        func pipeline(_ vs: String, _ fs: String, blend: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs)
            d.fragmentFunction = lib.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = colorFormat
            if blend {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor = .one
                d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            d.depthAttachmentPixelFormat = depthFormat
            d.rasterSampleCount = sampleCount
            return try device.makeRenderPipelineState(descriptor: d)
        }
        sheetPSO = try pipeline("sheet_vs", "sheet_fs", blend: false)
        floorPSO = try pipeline("floor_vs", "floor_fs", blend: true)

        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = lib.makeFunction(name: "shadow_vs")
        sd.fragmentFunction = lib.makeFunction(name: "shadow_fs")
        sd.colorAttachments[0].pixelFormat = .r32Float
        sd.depthAttachmentPixelFormat = .depth32Float
        shadowPSO = try device.makeRenderPipelineState(descriptor: sd)

        let dl = MTLDepthStencilDescriptor()
        dl.depthCompareFunction = .less
        dl.isDepthWriteEnabled = true
        depthLess = device.makeDepthStencilState(descriptor: dl)!
        let da = MTLDepthStencilDescriptor()
        da.depthCompareFunction = .always
        da.isDepthWriteEnabled = false
        depthAlways = device.makeDepthStencilState(descriptor: da)!

        let ts = MTLSamplerDescriptor()
        ts.minFilter = .linear
        ts.magFilter = .linear
        ts.mipFilter = .linear
        ts.maxAnisotropy = 16
        ts.sAddressMode = .clampToEdge
        ts.tAddressMode = .clampToEdge
        texSampler = device.makeSamplerState(descriptor: ts)!
        let ns = MTLSamplerDescriptor()
        ns.minFilter = .nearest
        ns.magFilter = .nearest
        ns.sAddressMode = .clampToEdge
        ns.tAddressMode = .clampToEdge
        nearestSampler = device.makeSamplerState(descriptor: ns)!
    }

    private func ensureShadowTargets(_ size: SIMD2<Float>) {
        let w = max(1, Int(size.x)), h = max(1, Int(size.y))
        if let t = shadowTex, t.width == w, t.height == h { return }
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]
        cd.storageMode = .private
        shadowTex = device.makeTexture(descriptor: cd)
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        dd.usage = [.renderTarget]
        dd.storageMode = .private
        shadowDepth = device.makeTexture(descriptor: dd)
    }

    // Uploads the vertices of every sheet, fills the uniforms and encodes the passes. Returns false if there is nothing to draw.
    private func encode(sheets: [Sheet], camera: Camera, cmd: MTLCommandBuffer, pass: MTLRenderPassDescriptor) -> Bool {
        ensureShadowTargets(camera.size)
        guard let shadowTex, let shadowDepth else { return false }

        let k = SIMD2(shadowLight.x, shadowLight.y) / shadowLight.z
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        var vbs: [MTLBuffer] = []
        for sh in sheets {
            let cloth = sh.cloth, mesh = sh.mesh
            let vb = mesh.vbufs[mesh.vIndex]
            mesh.vIndex = (mesh.vIndex + 1) % mesh.vbufs.count
            vbs.append(vb)
            let ptr = vb.contents().bindMemory(to: GPUVertex.self, capacity: cloth.count)
            for i in 0..<cloth.count {
                let p = cloth.pos[i]
                ptr[i] = GPUVertex(pos: SIMD4(p, 1), nrm: SIMD4(cloth.nrm[i], 0))
                let f = SIMD2(p.x, p.y) - k * p.z
                lo = simd_min(lo, simd_min(f, cloth.proj[i]))
                hi = simd_max(hi, simd_max(f, cloth.proj[i]))
            }
        }
        lo -= 48
        hi += 48

        var u = Uniforms()
        u.lightDir = SIMD4(shadeLight, 0)
        u.floorRect = sheets.isEmpty ? SIMD4(0, 0, 0, 0) : SIMD4(lo.x, lo.y, hi.x, hi.y)
        u.viewSize = camera.size
        u.lightK = k
        u.shadowMapSize = camera.size
        u.camD = camera.D
        let ulen = MemoryLayout<Uniforms>.stride

        let spd = MTLRenderPassDescriptor()
        spd.colorAttachments[0].texture = shadowTex
        spd.colorAttachments[0].loadAction = .clear
        spd.colorAttachments[0].clearColor = MTLClearColor(red: -10000, green: 0, blue: 0, alpha: 0)
        spd.colorAttachments[0].storeAction = .store
        spd.depthAttachment.texture = shadowDepth
        spd.depthAttachment.loadAction = .clear
        spd.depthAttachment.clearDepth = 1
        spd.depthAttachment.storeAction = .dontCare
        if let enc = cmd.makeRenderCommandEncoder(descriptor: spd) {
            enc.setRenderPipelineState(shadowPSO)
            enc.setDepthStencilState(depthLess)
            enc.setCullMode(.none)
            enc.setVertexBytes(&u, length: ulen, index: 2)
            enc.setFragmentSamplerState(texSampler, index: 0)
            for (n, sh) in sheets.enumerated() {
                enc.setVertexBuffer(vbs[n], offset: 0, index: 0)
                enc.setVertexBuffer(sh.mesh.uvbuf, offset: 0, index: 1)
                enc.setFragmentTexture(sh.texture, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: sh.mesh.indexCount, indexType: .uint32, indexBuffer: sh.mesh.ibuf, indexBufferOffset: 0)
            }
            enc.endEncoding()
        }

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return false }
        if !sheets.isEmpty {
            enc.setRenderPipelineState(floorPSO)
            enc.setDepthStencilState(depthAlways)
            enc.setVertexBytes(&u, length: ulen, index: 2)
            enc.setFragmentBytes(&u, length: ulen, index: 2)
            enc.setFragmentTexture(shadowTex, index: 1)
            enc.setFragmentSamplerState(nearestSampler, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        enc.setRenderPipelineState(sheetPSO)
        enc.setDepthStencilState(depthLess)
        enc.setCullMode(.none)
        enc.setFrontFacing(.counterClockwise)
        enc.setFragmentSamplerState(texSampler, index: 0)
        enc.setVertexBytes(&u, length: ulen, index: 2)
        enc.setFragmentBytes(&u, length: ulen, index: 2)
        for (n, sh) in sheets.enumerated() {
            enc.setVertexBuffer(vbs[n], offset: 0, index: 0)
            enc.setVertexBuffer(sh.mesh.uvbuf, offset: 0, index: 1)
            enc.setFragmentTexture(sh.texture, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: sh.mesh.indexCount, indexType: .uint32, indexBuffer: sh.mesh.ibuf, indexBufferOffset: 0)
        }
        enc.endEncoding()
        return true
    }

    func draw(sheets: [Sheet], camera: Camera, in view: MTKView) {
        inflight.wait()
        guard let cmd = queue.makeCommandBuffer() else { inflight.signal(); return }
        let sem = inflight
        cmd.addCompletedHandler { _ in sem.signal() }
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              encode(sheets: sheets, camera: camera, cmd: cmd, pass: rpd) else {
            cmd.commit()
            return
        }
        cmd.present(drawable)
        cmd.commit()
    }

    // A frame rendered into an image with a transparent background, for checking the look without a screen.
    func snapshot(sheets: [Sheet], camera: Camera, scale: Int) -> CGImage? {
        let w = Int(camera.size.x) * scale, h = Int(camera.size.y) * scale
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat, width: w, height: h, mipmapped: false)
        md.textureType = .type2DMultisample
        md.sampleCount = sampleCount
        md.usage = .renderTarget
        md.storageMode = .private
        let rd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat, width: w, height: h, mipmapped: false)
        rd.usage = [.renderTarget, .shaderRead]
        rd.storageMode = .shared
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: depthFormat, width: w, height: h, mipmapped: false)
        dd.textureType = .type2DMultisample
        dd.sampleCount = sampleCount
        dd.usage = .renderTarget
        dd.storageMode = .private
        guard let msaa = device.makeTexture(descriptor: md), let resolve = device.makeTexture(descriptor: rd),
              let depth = device.makeTexture(descriptor: dd), let cmd = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = resolve
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard encode(sheets: sheets, camera: camera, cmd: cmd, pass: pass) else { return nil }
        cmd.commit()
        cmd.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        resolve.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue) else { return nil }
        return ctx.makeImage()
    }
}
