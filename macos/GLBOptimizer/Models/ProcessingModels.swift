import Foundation

enum WorkMode: String, CaseIterable, Identifiable {
    case optimize
    case convert

    var id: String { rawValue }
    var title: String {
        switch self {
        case .optimize: return "优化"
        case .convert: return "转换"
        }
    }
}

enum PreviewSource: String, CaseIterable, Identifiable {
    case original
    case optimized

    var id: String { rawValue }
    var title: String { self == .original ? "原始" : "处理后" }
}

enum OptimizePreset: String, CaseIterable, Identifiable, Codable {
    case web
    case max
    case high
    case apple
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .web: return "Web 推荐"
        case .max: return "最大压缩"
        case .high: return "高质量"
        case .apple: return "macOS 兼容"
        case .custom: return "自定义"
        }
    }

    var subtitle: String {
        switch self {
        case .web: return "Meshopt + 1024px WebP，体积和质量比较均衡。只适合网页查看器（three.js、Babylon、model-viewer）。"
        case .max: return "Draco、更小的纹理，并简化网格。体积最小，细节会少一些。只适合网页查看器。"
        case .high: return "2048px WebP，几何只做压缩，不简化。只适合网页查看器。"
        case .apple: return "能用 macOS 预览和 Quick Look 打开。不压缩几何，纹理用 JPEG，并把网格简化到约 25%。体积比 Web 预设大。"
        case .custom: return "下面的选项可以单独调整。"
        }
    }
}

enum GeometryCompression: String, CaseIterable, Identifiable, Codable {
    case meshopt
    case draco
    case none

    var id: String { rawValue }
    var title: String {
        switch self {
        case .meshopt: return "Meshopt"
        case .draco: return "Draco"
        case .none: return "不压缩几何"
        }
    }
}

enum TextureFormatChoice: String, CaseIterable, Identifiable, Codable {
    case webp
    case jpeg
    case png
    case ktx2
    case keep

    var id: String { rawValue }
    var title: String {
        switch self {
        case .webp: return "WebP"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .ktx2: return "KTX2"
        case .keep: return "保持原格式"
        }
    }
}

enum MeshoptLevelChoice: String, CaseIterable, Identifiable, Codable {
    case medium
    case high

    var id: String { rawValue }
    var title: String { self == .high ? "高" : "中" }
}

struct OptimizeSettings: Equatable, Codable {
    var preset: OptimizePreset = .web
    var geometry: GeometryCompression = .meshopt
    var meshoptLevel: MeshoptLevelChoice = .medium
    var dracoEncodeSpeed: Int = 5
    var dracoPositionBits: Int = 14
    var dracoNormalBits: Int = 10
    var dracoTexcoordBits: Int = 12
    var textureFormat: TextureFormatChoice = .webp
    var textureMaxSize: Int = 1024
    var textureQuality: Int = 80
    var simplify: Bool = false
    var simplifyRatio: Double = 0.5
    var simplifyError: Double = 0.01
    var weld: Bool = true
    var resample: Bool = true
    var dedup: Bool = true
    var prune: Bool = true
    var sparse: Bool = true
    var instance: Bool = true
    var appleCompatible: Bool = false

    static let web = OptimizeSettings()

    static let apple = OptimizeSettings(
        preset: .apple,
        geometry: .none,
        textureFormat: .jpeg,
        textureMaxSize: 1024,
        textureQuality: 85,
        simplify: true,
        simplifyRatio: 0.25,
        simplifyError: 0.005,
        appleCompatible: true
    )

    static let max = OptimizeSettings(
        preset: .max,
        geometry: .draco,
        dracoEncodeSpeed: 1,
        dracoPositionBits: 11,
        dracoNormalBits: 8,
        dracoTexcoordBits: 10,
        textureFormat: .webp,
        textureMaxSize: 512,
        textureQuality: 60,
        simplify: true,
        simplifyRatio: 0.35,
        simplifyError: 0.02
    )

    static let high = OptimizeSettings(
        preset: .high,
        geometry: .meshopt,
        meshoptLevel: .high,
        textureFormat: .webp,
        textureMaxSize: 2048,
        textureQuality: 92,
        simplify: false
    )

    mutating func apply(_ preset: OptimizePreset) {
        switch preset {
        case .web: self = .web
        case .max: self = .max
        case .high: self = .high
        case .apple: self = .apple
        case .custom:
            self.preset = .custom
        }
    }

    mutating func edit(_ body: (inout OptimizeSettings) -> Void) {
        body(&self)
        preset = .custom
    }
}

enum ConvertTarget: String, CaseIterable, Identifiable, Codable {
    case stl
    case obj
    case gltf
    case glb

    var id: String { rawValue }
    var title: String {
        switch self {
        case .stl: return "STL（二进制，适合 3D 打印）"
        case .obj: return "OBJ"
        case .gltf: return "glTF（JSON + 外部文件）"
        case .glb: return "GLB"
        }
    }

    var fileExtension: String {
        switch self {
        case .stl: return "stl"
        case .obj: return "obj"
        case .gltf: return "gltf"
        case .glb: return "glb"
        }
    }
}

enum LengthUnit: String, CaseIterable, Identifiable, Codable {
    case m
    case mm
    case cm
    case inch

    var id: String { rawValue }
    var title: String {
        switch self {
        case .m: return "米"
        case .mm: return "毫米"
        case .cm: return "厘米"
        case .inch: return "英寸"
        }
    }
}

struct ConvertSettings: Equatable, Codable {
    var target: ConvertTarget = .stl
    var unit: LengthUnit = .mm
    var scale: Double = 1
    var center: Bool = false
    var weld: Bool = true
}

enum FileStatus: Equatable {
    case ready
    case running
    case succeeded
    case failed
}

struct SourceFile: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var byteSize: Int64
    var status: FileStatus = .ready
    var outputURL: URL?
    var outputBytes: Int64?
    var elapsed: TimeInterval?
    var triangleCount: Int?
    var message: String?

    var name: String { url.lastPathComponent }

    var isGLTF: Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "glb" || ext == "gltf"
    }
}

enum ToolchainStatus: Equatable {
    case checking
    case ready(node: URL, root: URL)
    case missingNode
    case needsInstall(node: URL, root: URL)
    case failed(String)
}

struct EngineEvent {
    enum Kind {
        case progress(message: String, fraction: Double?)
        case result(EngineResult)
        case error(String)
        case log(String)
    }

    var kind: Kind
}

struct EngineResult: Decodable {
    var output: String
    var inputBytes: Int64
    var outputBytes: Int64
    var elapsedMs: Double
    var triangles: Int?
    var warnings: [String]?
    var sourceTriangles: Int?
    var extensions: [String]?
    var simplified: Bool?
}
