import AppKit
import Foundation
import GLBCore

@MainActor
final class AppModel: ObservableObject {
    @Published var files: [SourceFile] = []
    @Published var selection: SourceFile.ID?
    @Published var mode: WorkMode = .optimize
    @Published var optimizeSettings: OptimizeSettings = .web
    @Published var convertSettings = ConvertSettings()
    @Published var outputDirectory: URL
    @Published var toolchain: ToolchainStatus = .checking
    @Published var isRunning = false
    @Published var isInstalling = false
    @Published var progress: Double = 0
    @Published var progressLabel = "空闲"
    @Published var logs: [String] = []
    @Published var previewSource: PreviewSource = .original {
        didSet { if oldValue != previewSource { refreshPreview() } }
    }
    @Published var previewMessage = "选择一个 GLB 或 glTF 查看模型。"
    @Published private(set) var previewScene: PreviewScene?
    @Published private(set) var isPreviewLoading = false
    @Published var isTargeted = false

    private let engine = EngineClient()
    private let previewEngine = EngineClient()
    private var previewTask: Task<Void, Never>?
    private var previewKey: String?
    private var previewCache: [String: (url: URL, result: EngineResult)] = [:]
    private var previewOrder: [String] = []
    private let previewDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("GLBOptimizer-preview", isDirectory: true)
    private var runTask: Task<Void, Never>?
    private var cancelled = false
    private let defaults = UserDefaults.standard

    init() {
        if let stored = defaults.string(forKey: "outputDirectory"), !stored.isEmpty {
            outputDirectory = URL(fileURLWithPath: stored, isDirectory: true)
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
            outputDirectory = documents.appendingPathComponent("GLB Optimizer", isDirectory: true)
        }
        if let data = defaults.data(forKey: "optimizeSettings"),
           let stored = try? JSONDecoder().decode(OptimizeSettings.self, from: data) {
            optimizeSettings = stored
        }
        if let data = defaults.data(forKey: "convertSettings"),
           let stored = try? JSONDecoder().decode(ConvertSettings.self, from: data) {
            convertSettings = stored
        }
    }

    func refreshToolchain() {
        toolchain = ToolchainLocator.resolve()
        switch toolchain {
        case .ready:
            appendLog("优化引擎已就绪。文件只在本机处理。")
        case .missingNode:
            appendLog("没有找到 Node.js。安装命令：brew install node")
        case .needsInstall:
            appendLog("已找到 Node.js，还需要安装 glTF-Transform。点击「安装优化引擎」。")
        case .failed(let message):
            appendLog(message)
        case .checking:
            break
        }
        refreshPreview()
    }

    func installToolchain() {
        guard !isInstalling else { return }
        guard case .needsInstall(let node, let source) = toolchain else {
            refreshToolchain()
            return
        }
        let destination = ToolchainLocator.installRoot() ?? ToolchainLocator.supportDirectory
        isInstalling = true
        appendLog("正在安装优化引擎，第一次需要联网下载依赖……")
        Task {
            do {
                try await engine.installDependencies(node: node, source: source, destination: destination)
                appendLog("优化引擎安装完成。")
            } catch {
                appendLog(error.localizedDescription)
            }
            isInstalling = false
            refreshToolchain()
        }
    }

    func addFiles(_ urls: [URL]) {
        let accepted = ["glb", "gltf", "stl", "obj"]
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard accepted.contains(ext) else {
                appendLog("已跳过 \(url.lastPathComponent)：目前支持 glb、gltf、stl、obj。")
                continue
            }
            if files.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let file = SourceFile(url: url, byteSize: size)
            files.append(file)
            if selection == nil { select(file.id) }
        }
    }

    func removeSelected() {
        guard let selection else { return }
        files.removeAll { $0.id == selection }
        select(files.first?.id)
    }

    func removeAll() {
        files.removeAll()
        select(nil)
    }

    func select(_ id: SourceFile.ID?) {
        if selection != id { selection = id }
        previewSource = .original
        refreshPreview()
    }

    var selectedFile: SourceFile? {
        files.first { $0.id == selection }
    }

    var previewURL: URL? {
        guard let file = selectedFile else { return nil }
        if previewSource == .optimized, let output = file.outputURL, output.pathExtension.lowercased() == "glb" {
            return output
        }
        let ext = file.url.pathExtension.lowercased()
        return ext == "glb" || ext == "gltf" ? file.url : nil
    }

    /// SceneKit cannot read Draco, Meshopt, quantized or WebP data, so the toolchain first
    /// writes a decoded copy of the model and the app renders that copy.
    func refreshPreview() {
        guard let file = selectedFile, let url = previewURL else {
            stopPreview()
            if let file = selectedFile {
                previewMessage = file.isGLTF ? "无法预览这个文件。" : "STL 和 OBJ 不提供预览，可以先转换成 GLB。"
            } else {
                previewMessage = "选择一个 GLB 或 glTF 查看模型。"
            }
            return
        }
        guard case .ready(let node, let root) = toolchain else {
            stopPreview()
            previewMessage = "优化引擎就绪后才能预览 \(file.name)。"
            return
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        guard key != previewKey else { return }
        stopPreview()
        previewKey = key
        isPreviewLoading = true
        previewMessage = "正在生成预览……"
        let toolchain = ResolvedToolchain(node: node, root: root)
        let cached = previewCache[key]
        let output = previewDirectory.appendingPathComponent("\(UUID().uuidString).glb")
        previewTask = Task {
            do {
                let prepared: (url: URL, result: EngineResult)
                if let cached {
                    prepared = cached
                } else {
                    try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
                    let result = try await previewEngine.preview(input: url, output: output, toolchain: toolchain)
                    prepared = (output, result)
                    rememberPreview(prepared, for: key)
                }
                guard !Task.isCancelled else { return }
                let previewFile = prepared.url
                let scene = try await Task.detached(priority: .userInitiated) {
                    try GLBSceneLoader.load(previewFile)
                }.value
                guard !Task.isCancelled, previewKey == key else { return }
                previewScene = scene
                isPreviewLoading = false
                previewMessage = Self.previewSummary(scene, result: prepared.result)
            } catch {
                guard !Task.isCancelled, previewKey == key else { return }
                isPreviewLoading = false
                previewMessage = "无法预览：\(error.localizedDescription)"
                appendLog("\(file.name) 预览失败：\(error.localizedDescription)")
            }
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewEngine.cancel()
        previewKey = nil
        previewScene = nil
        isPreviewLoading = false
    }

    private func rememberPreview(_ entry: (url: URL, result: EngineResult), for key: String) {
        previewCache[key] = entry
        previewOrder.append(key)
        while previewOrder.count > 8 {
            let evicted = previewOrder.removeFirst()
            if let old = previewCache.removeValue(forKey: evicted) {
                try? FileManager.default.removeItem(at: old.url)
            }
        }
    }

    private static func previewSummary(_ scene: PreviewScene, result: EngineResult) -> String {
        var parts: [String] = []
        if result.simplified == true, let source = result.sourceTriangles {
            parts.append("\(source.formatted()) 个三角面（预览简化为 \(scene.triangles.formatted())）")
        } else {
            parts.append("\(scene.triangles.formatted()) 个三角面")
        }
        parts.append("\(scene.meshes) 个网格")
        parts.append("\(scene.textures) 张纹理")
        if let extensions = result.extensions, !extensions.isEmpty {
            parts.append(extensions.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "优化和转换后的文件会写到这个文件夹。"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
            defaults.set(url.path, forKey: "outputDirectory")
        }
    }

    func persistSettings() {
        if let data = try? JSONEncoder().encode(optimizeSettings) {
            defaults.set(data, forKey: "optimizeSettings")
        }
        if let data = try? JSONEncoder().encode(convertSettings) {
            defaults.set(data, forKey: "convertSettings")
        }
    }

    func openOutputDirectory() {
        let url = outputDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func start() {
        guard !isRunning else { return }
        guard !files.isEmpty else {
            appendLog("请先加入要处理的文件。")
            return
        }
        guard case .ready(let node, let root) = toolchain else {
            appendLog(toolchain.blockedMessage)
            return
        }
        if convertSettings.scale <= 0 {
            appendLog("缩放倍率必须大于 0。")
            return
        }
        persistSettings()
        cancelled = false
        isRunning = true
        progress = 0
        let toolchain = ResolvedToolchain(node: node, root: root)
        let targets = files.map(\.id)
        for index in files.indices {
            files[index].status = .ready
            files[index].message = nil
            files[index].outputURL = nil
            files[index].outputBytes = nil
        }
        runTask = Task {
            await process(ids: targets, toolchain: toolchain)
        }
    }

    func cancel() {
        cancelled = true
        engine.cancel()
        progressLabel = "正在取消"
        appendLog("正在取消当前任务……")
    }

    private func process(ids: [SourceFile.ID], toolchain: ResolvedToolchain) async {
        var usedNames = Set<String>()
        var succeeded = 0
        for (offset, id) in ids.enumerated() {
            if cancelled { break }
            guard let index = files.firstIndex(where: { $0.id == id }) else { continue }
            let file = files[index]
            if mode == .optimize && !file.isGLTF {
                files[index].status = .failed
                files[index].message = "优化只接受 .glb / .gltf"
                appendLog("\(file.name)：优化只接受 .glb / .gltf，已跳过。")
                continue
            }
            if mode == .convert && !canConvert(file) {
                files[index].status = .failed
                files[index].message = "这个输入不能转到所选格式"
                appendLog("\(file.name)：不能转换成 \(convertSettings.target.title)。")
                continue
            }
            let output = outputURL(for: file, usedNames: &usedNames)
            files[index].status = .running
            let started = Date()
            progressLabel = "\(offset + 1)/\(ids.count) · \(file.name)"
            appendLog("开始处理 \(file.name)")
            do {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                let result: EngineResult
                if mode == .optimize {
                    result = try await engine.optimize(
                        job: optimizeSettings,
                        input: file.url,
                        output: output,
                        toolchain: toolchain
                    ) { [weak self] event in
                        Task { @MainActor in self?.handle(event) }
                    }
                } else {
                    result = try await engine.convert(
                        job: convertSettings,
                        input: file.url,
                        output: output,
                        toolchain: toolchain
                    ) { [weak self] event in
                        Task { @MainActor in self?.handle(event) }
                    }
                }
                if let current = files.firstIndex(where: { $0.id == id }) {
                    files[current].status = .succeeded
                    files[current].outputURL = URL(fileURLWithPath: result.output)
                    files[current].outputBytes = result.outputBytes
                    files[current].elapsed = result.elapsedMs / 1000
                    files[current].triangleCount = result.triangles
                    files[current].message = ByteFormat.ratio(output: result.outputBytes, input: max(result.inputBytes, 1))
                    succeeded += 1
                    if selection == id, mode == .optimize {
                        previewSource = .optimized
                        refreshPreview()
                    }
                    appendLog("\(file.name)：\(ByteFormat.string(result.inputBytes)) → \(ByteFormat.string(result.outputBytes))，\(files[current].message ?? "")，用时 \(duration(Date().timeIntervalSince(started)))。")
                    for warning in result.warnings ?? [] {
                        appendLog("注意：\(warning)")
                    }
                }
            } catch {
                if let current = files.firstIndex(where: { $0.id == id }) {
                    files[current].status = cancelled ? .failed : .failed
                    files[current].message = cancelled ? "已取消" : error.localizedDescription
                    files[current].elapsed = Date().timeIntervalSince(started)
                }
                appendLog("\(file.name)：\(cancelled ? "已取消" : error.localizedDescription)")
                if cancelled { break }
            }
            progress = Double(offset + 1) / Double(ids.count)
        }
        isRunning = false
        progressLabel = cancelled ? "已取消" : "完成 \(succeeded)/\(ids.count)"
        if !cancelled {
            appendLog("队列结束：成功 \(succeeded) 个，共 \(ids.count) 个。输出目录：\(outputDirectory.path)")
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event.kind {
        case .progress(let message, let fraction):
            if let fraction, let current = files.firstIndex(where: { $0.status == .running }) {
                let completed = files[..<current].count
                progress = (Double(completed) + fraction) / Double(max(files.count, 1))
            }
            progressLabel = message
            appendLog(message)
        case .error(let message):
            appendLog(message)
        case .log(let message):
            appendLog(message)
        case .result:
            break
        }
    }

    private func outputURL(for file: SourceFile, usedNames: inout Set<String>) -> URL {
        let base = file.url.deletingPathExtension().lastPathComponent
        let ext: String
        let suffix: String
        if mode == .optimize {
            ext = "glb"
            suffix = optimizeSettings.appleCompatible ? ".macos" : ".optimized"
        } else {
            ext = convertSettings.target.fileExtension
            suffix = ".converted"
        }
        var name = "\(base)\(suffix).\(ext)"
        var counter = 2
        while usedNames.contains(name) {
            name = "\(base)\(suffix)-\(counter).\(ext)"
            counter += 1
        }
        usedNames.insert(name)
        return outputDirectory.appendingPathComponent(name)
    }

    private func canConvert(_ file: SourceFile) -> Bool {
        let ext = file.url.pathExtension.lowercased()
        switch convertSettings.target {
        case .stl, .obj, .gltf:
            return ext == "glb" || ext == "gltf"
        case .glb:
            return ext == "glb" || ext == "gltf" || ext == "stl" || ext == "obj"
        }
    }

    private func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logs.append(trimmed)
        if logs.count > 400 {
            logs.removeFirst(logs.count - 400)
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1f 秒", seconds) }
        let minutes = Int(seconds) / 60
        let remain = Int(seconds) % 60
        return "\(minutes) 分 \(remain) 秒"
    }
}

extension ToolchainStatus {
    var blockedMessage: String {
        switch self {
        case .checking: return "正在检查优化引擎。"
        case .ready: return "优化引擎已就绪。"
        case .missingNode: return "没有找到 Node.js。请先运行：brew install node"
        case .needsInstall: return "优化引擎还没安装。请点击「安装优化引擎」。"
        case .failed(let message): return message
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
