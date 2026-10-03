import AppKit
import SceneKit
import simd

struct PreviewScene {
    var scene: SCNScene
    var center: SIMD3<Float>
    var radius: Float
    var triangles: Int
    var meshes: Int
    var textures: Int
}

enum GLBLoadError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "预览文件无法解析：\(reason)"
        }
    }
}

/// Builds a SceneKit scene from a GLB that `preview.mjs` already decoded: float or
/// integer accessors, no compression extensions, PNG/JPEG images.
final class GLBSceneLoader {
    private let json: [String: Any]
    private let bin: Data
    private var images: [Int: NSImage] = [:]
    private var materials: [Int: SCNMaterial] = [:]
    private var meshNodes: [Int: [SCNNode]] = [:]
    private var triangles = 0

    static func load(_ url: URL) throws -> PreviewScene {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try GLBSceneLoader(data: data).build()
    }

    private init(data: Data) throws {
        guard data.count >= 20, data.readUInt32(at: 0) == 0x4654_6C67 else {
            throw GLBLoadError.invalid("不是 GLB 文件")
        }
        var offset = 12
        var json: [String: Any]?
        var bin = Data()
        while offset + 8 <= data.count {
            let length = Int(data.readUInt32(at: offset))
            let type = data.readUInt32(at: offset + 4)
            let start = offset + 8
            guard start + length <= data.count else { throw GLBLoadError.invalid("数据块长度越界") }
            let chunk = data.subdata(in: start..<(start + length))
            if type == 0x4E4F_534A {
                json = try JSONSerialization.jsonObject(with: chunk) as? [String: Any]
            } else if type == 0x004E_4942 {
                bin = chunk
            }
            offset = start + length
        }
        guard let json else { throw GLBLoadError.invalid("缺少 JSON 数据块") }
        self.json = json
        self.bin = bin
    }

    private func build() throws -> PreviewScene {
        let scenes = json["scenes"] as? [[String: Any]] ?? []
        let sceneIndex = json["scene"] as? Int ?? 0
        var roots: [Int] = []
        if scenes.indices.contains(sceneIndex) {
            roots = scenes[sceneIndex]["nodes"] as? [Int] ?? []
        } else {
            roots = Array((json["nodes"] as? [Any] ?? []).indices)
        }

        let scene = SCNScene()
        let model = SCNNode()
        for index in roots {
            if let node = try makeNode(index, depth: 0) { model.addChildNode(node) }
        }
        scene.rootNode.addChildNode(model)

        let (low, high) = model.boundingBox
        let lower = SIMD3<Float>(Float(low.x), Float(low.y), Float(low.z))
        let upper = SIMD3<Float>(Float(high.x), Float(high.y), Float(high.z))
        let valid = upper.x >= lower.x
        return PreviewScene(
            scene: scene,
            center: valid ? (lower + upper) / 2 : .zero,
            radius: valid ? max(simd_length(upper - lower) / 2, 1e-4) : 1,
            triangles: triangles,
            meshes: meshNodes.count,
            textures: images.count
        )
    }

    private func makeNode(_ index: Int, depth: Int) throws -> SCNNode? {
        let nodes = json["nodes"] as? [[String: Any]] ?? []
        guard nodes.indices.contains(index), depth < 64 else { return nil }
        let info = nodes[index]
        let node = SCNNode()
        node.name = info["name"] as? String
        node.simdTransform = Self.transform(info)

        if let mesh = info["mesh"] as? Int {
            let primitives = try meshPrimitives(mesh)
            let instancing = (info["extensions"] as? [String: Any])?["EXT_mesh_gpu_instancing"] as? [String: Any]
            if let attributes = instancing?["attributes"] as? [String: Int] {
                for transform in try instanceTransforms(attributes) {
                    let instance = SCNNode()
                    instance.simdTransform = transform
                    primitives.forEach { instance.addChildNode($0.clone()) }
                    node.addChildNode(instance)
                }
            } else {
                primitives.forEach { node.addChildNode($0.clone()) }
            }
        }
        for child in info["children"] as? [Int] ?? [] {
            if let childNode = try makeNode(child, depth: depth + 1) { node.addChildNode(childNode) }
        }
        return node
    }

    private static func transform(_ info: [String: Any]) -> simd_float4x4 {
        if let m = (info["matrix"] as? [NSNumber])?.map(\.floatValue), m.count == 16 {
            return simd_float4x4(columns: (
                SIMD4(m[0], m[1], m[2], m[3]),
                SIMD4(m[4], m[5], m[6], m[7]),
                SIMD4(m[8], m[9], m[10], m[11]),
                SIMD4(m[12], m[13], m[14], m[15])
            ))
        }
        let t = (info["translation"] as? [NSNumber])?.map(\.floatValue) ?? [0, 0, 0]
        let r = (info["rotation"] as? [NSNumber])?.map(\.floatValue) ?? [0, 0, 0, 1]
        let s = (info["scale"] as? [NSNumber])?.map(\.floatValue) ?? [1, 1, 1]
        return compose(
            translation: SIMD3(t[safe: 0], t[safe: 1], t[safe: 2]),
            rotation: simd_quatf(ix: r[safe: 0], iy: r[safe: 1], iz: r[safe: 2], r: r.count > 3 ? r[3] : 1),
            scale: SIMD3(s.count > 0 ? s[0] : 1, s.count > 1 ? s[1] : 1, s.count > 2 ? s[2] : 1)
        )
    }

    private static func compose(translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) -> simd_float4x4 {
        var matrix = simd_float4x4(rotation.normalized)
        matrix.columns.0 *= scale.x
        matrix.columns.1 *= scale.y
        matrix.columns.2 *= scale.z
        matrix.columns.3 = SIMD4(translation, 1)
        return matrix
    }

    private func instanceTransforms(_ attributes: [String: Int]) throws -> [simd_float4x4] {
        let translations = try attributes["TRANSLATION"].map { try floats($0, components: 3) }
        let rotations = try attributes["ROTATION"].map { try floats($0, components: 4) }
        let scales = try attributes["SCALE"].map { try floats($0, components: 3) }
        let count = [translations.map { $0.count / 3 }, rotations.map { $0.count / 4 }, scales.map { $0.count / 3 }]
            .compactMap { $0 }.max() ?? 0
        return (0..<count).map { i in
            let t = translations.map { SIMD3($0[i * 3], $0[i * 3 + 1], $0[i * 3 + 2]) } ?? .zero
            let r = rotations.map { simd_quatf(ix: $0[i * 4], iy: $0[i * 4 + 1], iz: $0[i * 4 + 2], r: $0[i * 4 + 3]) }
                ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            let s = scales.map { SIMD3($0[i * 3], $0[i * 3 + 1], $0[i * 3 + 2]) } ?? SIMD3(repeating: 1)
            return Self.compose(translation: t, rotation: r, scale: s)
        }
    }

    // MARK: Meshes

    private func meshPrimitives(_ index: Int) throws -> [SCNNode] {
        if let cached = meshNodes[index] { return cached }
        let meshes = json["meshes"] as? [[String: Any]] ?? []
        guard meshes.indices.contains(index) else { return [] }
        var nodes: [SCNNode] = []
        for primitive in meshes[index]["primitives"] as? [[String: Any]] ?? [] {
            if let geometry = try makeGeometry(primitive) { nodes.append(SCNNode(geometry: geometry)) }
        }
        meshNodes[index] = nodes
        return nodes
    }

    private func makeGeometry(_ primitive: [String: Any]) throws -> SCNGeometry? {
        let mode = primitive["mode"] as? Int ?? 4
        guard (4...6).contains(mode),
              let attributes = primitive["attributes"] as? [String: Int],
              let positionIndex = attributes["POSITION"] else { return nil }

        let positions = try floats(positionIndex, components: 3)
        let vertexCount = positions.count / 3
        guard vertexCount > 0 else { return nil }
        var sources = [Self.source(positions, semantic: .vertex, components: 3)]
        if let normalIndex = attributes["NORMAL"] {
            let normals = try floats(normalIndex, components: 3)
            if normals.count == positions.count { sources.append(Self.source(normals, semantic: .normal, components: 3)) }
        }
        if let uvIndex = attributes["TEXCOORD_0"] {
            let uvs = try floats(uvIndex, components: 2)
            if uvs.count == vertexCount * 2 { sources.append(Self.source(uvs, semantic: .texcoord, components: 2)) }
        }

        var indices: [UInt32]
        if let indexAccessor = primitive["indices"] as? Int {
            indices = try integers(indexAccessor)
        } else {
            indices = (0..<UInt32(vertexCount)).map { $0 }
        }
        indices = Self.triangleList(indices, mode: mode).filter { Int($0) < vertexCount }
        indices.removeLast(indices.count % 3)
        guard !indices.isEmpty else { return nil }
        triangles += indices.count / 3

        let element = SCNGeometryElement(
            data: indices.withUnsafeBufferPointer { Data(buffer: $0) },
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: sources, elements: [element])
        geometry.materials = [material(primitive["material"] as? Int)]
        return geometry
    }

    private static func triangleList(_ indices: [UInt32], mode: Int) -> [UInt32] {
        guard indices.count >= 3, mode != 4 else { return indices }
        var list: [UInt32] = []
        list.reserveCapacity((indices.count - 2) * 3)
        for i in 2..<indices.count {
            if mode == 5 {
                list += i % 2 == 0 ? [indices[i - 2], indices[i - 1], indices[i]] : [indices[i - 1], indices[i - 2], indices[i]]
            } else {
                list += [indices[0], indices[i - 1], indices[i]]
            }
        }
        return list
    }

    private static func source(_ values: [Float], semantic: SCNGeometrySource.Semantic, components: Int) -> SCNGeometrySource {
        SCNGeometrySource(
            data: values.withUnsafeBufferPointer { Data(buffer: $0) },
            semantic: semantic,
            vectorCount: values.count / components,
            usesFloatComponents: true,
            componentsPerVector: components,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * components
        )
    }

    // MARK: Materials

    private func material(_ index: Int?) -> SCNMaterial {
        if let index, let cached = materials[index] { return cached }
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        let list = json["materials"] as? [[String: Any]] ?? []
        guard let index, list.indices.contains(index) else {
            material.diffuse.contents = NSColor(white: 0.8, alpha: 1)
            material.metalness.contents = 0.0
            material.roughness.contents = 0.6
            return material
        }
        let info = list[index]
        let pbr = info["pbrMetallicRoughness"] as? [String: Any] ?? [:]

        let factor = (pbr["baseColorFactor"] as? [NSNumber])?.map { CGFloat($0.doubleValue) } ?? [1, 1, 1, 1]
        let alpha = factor.count > 3 ? factor[3] : 1
        if let image = texture(pbr["baseColorTexture"]) {
            material.diffuse.contents = image
            if factor.prefix(3).contains(where: { $0 < 0.999 }) {
                material.multiply.contents = NSColor(red: factor[0], green: factor[1], blue: factor[2], alpha: 1)
            }
        } else {
            material.diffuse.contents = NSColor(red: factor[safe: 0], green: factor[safe: 1], blue: factor[safe: 2], alpha: 1)
        }

        let metallic = CGFloat((pbr["metallicFactor"] as? NSNumber)?.doubleValue ?? 1)
        let roughness = CGFloat((pbr["roughnessFactor"] as? NSNumber)?.doubleValue ?? 1)
        if let image = texture(pbr["metallicRoughnessTexture"]) {
            material.metalness.contents = image
            material.metalness.textureComponents = .blue
            material.metalness.intensity = metallic
            material.roughness.contents = image
            material.roughness.textureComponents = .green
            material.roughness.intensity = roughness
        } else {
            material.metalness.contents = metallic
            material.roughness.contents = roughness
        }

        if let image = texture(info["normalTexture"]) {
            material.normal.contents = image
            material.normal.intensity = CGFloat(((info["normalTexture"] as? [String: Any])?["scale"] as? NSNumber)?.doubleValue ?? 1)
        }
        if let image = texture(info["occlusionTexture"]) {
            material.ambientOcclusion.contents = image
            material.ambientOcclusion.textureComponents = .red
        }
        if let image = texture(info["emissiveTexture"]) {
            material.emission.contents = image
        } else if let emissive = (info["emissiveFactor"] as? [NSNumber])?.map({ CGFloat($0.doubleValue) }),
                  emissive.contains(where: { $0 > 0 }) {
            material.emission.contents = NSColor(red: emissive[safe: 0], green: emissive[safe: 1], blue: emissive[safe: 2], alpha: 1)
        }

        let alphaMode = info["alphaMode"] as? String ?? "OPAQUE"
        if alphaMode != "OPAQUE" {
            material.transparencyMode = .aOne
            material.transparency = alpha
            if alphaMode == "BLEND" {
                material.blendMode = .alpha
                material.writesToDepthBuffer = false
            }
        }
        material.isDoubleSided = info["doubleSided"] as? Bool ?? false
        materials[index] = material
        return material
    }

    private func texture(_ reference: Any?) -> NSImage? {
        guard let reference = reference as? [String: Any],
              let textureIndex = reference["index"] as? Int else { return nil }
        let textures = json["textures"] as? [[String: Any]] ?? []
        guard textures.indices.contains(textureIndex),
              let imageIndex = textures[textureIndex]["source"] as? Int else { return nil }
        if let cached = images[imageIndex] { return cached }
        let list = json["images"] as? [[String: Any]] ?? []
        guard list.indices.contains(imageIndex),
              let view = list[imageIndex]["bufferView"] as? Int,
              let range = try? bufferViewRange(view),
              let image = NSImage(data: bin.subdata(in: range)) else { return nil }
        images[imageIndex] = image
        return image
    }

    // MARK: Accessors

    private func bufferViewRange(_ index: Int) throws -> Range<Int> {
        let views = json["bufferViews"] as? [[String: Any]] ?? []
        guard views.indices.contains(index) else { throw GLBLoadError.invalid("bufferView \(index) 不存在") }
        let start = views[index]["byteOffset"] as? Int ?? 0
        let length = views[index]["byteLength"] as? Int ?? 0
        guard start >= 0, length >= 0, start + length <= bin.count else { throw GLBLoadError.invalid("bufferView \(index) 越界") }
        return start..<(start + length)
    }

    private struct AccessorLayout {
        var start: Int
        var count: Int
        var components: Int
        var componentType: Int
        var componentSize: Int
        var stride: Int
        var normalized: Bool
    }

    private func layout(_ index: Int) throws -> AccessorLayout {
        let accessors = json["accessors"] as? [[String: Any]] ?? []
        guard accessors.indices.contains(index) else { throw GLBLoadError.invalid("accessor \(index) 不存在") }
        let accessor = accessors[index]
        guard let view = accessor["bufferView"] as? Int else { throw GLBLoadError.invalid("accessor \(index) 没有数据") }
        let components = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16][accessor["type"] as? String ?? ""] ?? 1
        let componentType = accessor["componentType"] as? Int ?? 5126
        let componentSize = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][componentType] ?? 4
        let views = json["bufferViews"] as? [[String: Any]] ?? []
        let range = try bufferViewRange(view)
        let stride = (views[view]["byteStride"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? components * componentSize
        let start = range.lowerBound + (accessor["byteOffset"] as? Int ?? 0)
        let count = accessor["count"] as? Int ?? 0
        guard count >= 0, count == 0 || start + (count - 1) * stride + components * componentSize <= range.upperBound else {
            throw GLBLoadError.invalid("accessor \(index) 越界")
        }
        return AccessorLayout(
            start: start, count: count, components: components, componentType: componentType,
            componentSize: componentSize, stride: stride, normalized: accessor["normalized"] as? Bool ?? false
        )
    }

    private func floats(_ index: Int, components expected: Int) throws -> [Float] {
        let layout = try layout(index)
        guard layout.components == expected else { throw GLBLoadError.invalid("accessor \(index) 分量数不符") }
        var values = [Float](repeating: 0, count: layout.count * expected)
        bin.withUnsafeBytes { raw in
            for i in 0..<layout.count {
                let base = layout.start + i * layout.stride
                for c in 0..<expected {
                    let at = base + c * layout.componentSize
                    let value: Float
                    switch layout.componentType {
                    case 5126: value = raw.loadUnaligned(fromByteOffset: at, as: Float.self)
                    case 5120:
                        let v = Float(raw.loadUnaligned(fromByteOffset: at, as: Int8.self))
                        value = layout.normalized ? max(v / 127, -1) : v
                    case 5121:
                        let v = Float(raw.loadUnaligned(fromByteOffset: at, as: UInt8.self))
                        value = layout.normalized ? v / 255 : v
                    case 5122:
                        let v = Float(raw.loadUnaligned(fromByteOffset: at, as: Int16.self))
                        value = layout.normalized ? max(v / 32767, -1) : v
                    case 5123:
                        let v = Float(raw.loadUnaligned(fromByteOffset: at, as: UInt16.self))
                        value = layout.normalized ? v / 65535 : v
                    default:
                        value = Float(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
                    }
                    values[i * expected + c] = value
                }
            }
        }
        return values
    }

    private func integers(_ index: Int) throws -> [UInt32] {
        let layout = try layout(index)
        var values = [UInt32](repeating: 0, count: layout.count)
        bin.withUnsafeBytes { raw in
            for i in 0..<layout.count {
                let at = layout.start + i * layout.stride
                switch layout.componentType {
                case 5121: values[i] = UInt32(raw.loadUnaligned(fromByteOffset: at, as: UInt8.self))
                case 5123: values[i] = UInt32(raw.loadUnaligned(fromByteOffset: at, as: UInt16.self))
                default: values[i] = raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)
                }
            }
        }
        return values
    }
}

private extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
}

private extension Array where Element: Numeric {
    subscript(safe index: Int) -> Element {
        indices.contains(index) ? self[index] : 0
    }
}
