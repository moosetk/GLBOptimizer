import Foundation

final class EngineClient {
    private let lock = NSLock()
    private var process: Process?

    func cancel() {
        lock.lock()
        let current = process
        lock.unlock()
        current?.terminate()
    }

    func installDependencies(node: URL, source: URL, destination: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        if source.standardizedFileURL != destination.standardizedFileURL {
            try copyScripts(from: source, to: destination)
        }
        let npm = node.deletingLastPathComponent().appendingPathComponent("npm")
        guard manager.isExecutableFile(atPath: npm.path) else {
            throw ToolchainError.commandFailed("在 \(node.deletingLastPathComponent().path) 里没有找到 npm。")
        }
        let code = try await run(
            executable: npm,
            arguments: ["install", "--omit=dev", "--no-fund", "--no-audit"],
            directory: destination
        ) { _, _ in }
        guard code == 0 else {
            throw ToolchainError.commandFailed("npm install 失败（退出码 \(code)）。请检查网络，或在工具链目录手动执行 npm install。")
        }
        guard ToolchainLocator.hasDependencies(destination) else {
            throw ToolchainError.commandFailed("依赖安装结束了，但没有找到 @gltf-transform/core。")
        }
    }

    func optimize(job: OptimizeSettings, input: URL, output: URL, toolchain: ResolvedToolchain, onEvent: @escaping (EngineEvent) -> Void) async throws -> EngineResult {
        let payload = OptimizePayload(settings: job, input: input, output: output)
        return try await runJob(script: "optimize.mjs", payload: payload, toolchain: toolchain, onEvent: onEvent)
    }

    func convert(job: ConvertSettings, input: URL, output: URL, toolchain: ResolvedToolchain, onEvent: @escaping (EngineEvent) -> Void) async throws -> EngineResult {
        let payload = ConvertPayload(settings: job, input: input, output: output)
        return try await runJob(script: "convert.mjs", payload: payload, toolchain: toolchain, onEvent: onEvent)
    }

    func preview(input: URL, output: URL, toolchain: ResolvedToolchain) async throws -> EngineResult {
        let payload = PreviewPayload(input: input.path, output: output.path, maxTriangles: 2_000_000, maxTextureSize: 2048)
        return try await runJob(script: "preview.mjs", payload: payload, toolchain: toolchain) { _ in }
    }

    private func runJob<T: Encodable>(script: String, payload: T, toolchain: ResolvedToolchain, onEvent: @escaping (EngineEvent) -> Void) async throws -> EngineResult {
        let jobURL = FileManager.default.temporaryDirectory.appendingPathComponent("glbopt-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(payload).write(to: jobURL)
        defer { try? FileManager.default.removeItem(at: jobURL) }

        let scriptURL = toolchain.root.appendingPathComponent(script)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw ToolchainError.commandFailed("找不到脚本 \(script)。")
        }

        var result: EngineResult?
        var failure: String?
        let code = try await run(
            executable: toolchain.node,
            arguments: [scriptURL.path, jobURL.path],
            directory: toolchain.root
        ) { line, isError in
            if isError {
                if line.contains("targets.cc") { return }
                onEvent(EngineEvent(kind: .log(line)))
                return
            }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                if !line.isEmpty { onEvent(EngineEvent(kind: .log(line))) }
                return
            }
            switch type {
            case "progress":
                onEvent(EngineEvent(kind: .progress(
                    message: object["message"] as? String ?? "处理中",
                    fraction: object["fraction"] as? Double
                )))
            case "result":
                if let parsed = try? JSONDecoder().decode(EngineResult.self, from: data) {
                    result = parsed
                }
            case "error":
                failure = object["message"] as? String ?? "优化引擎报错。"
                onEvent(EngineEvent(kind: .error(failure ?? "优化引擎报错。")))
            default:
                onEvent(EngineEvent(kind: .log(line)))
            }
        }

        if let failure {
            throw ToolchainError.commandFailed(failure)
        }
        if code != 0 {
            throw ToolchainError.commandFailed("处理失败（退出码 \(code)）。文件可能已损坏，或用了当前预设不支持的扩展。")
        }
        guard let result else {
            throw ToolchainError.commandFailed("脚本结束了，但没有返回结果。")
        }
        return result
    }

    private func run(
        executable: URL,
        arguments: [String],
        directory: URL,
        onLine: @escaping (_ line: String, _ isError: Bool) -> Void
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = ToolchainLocator.enrichedEnvironment()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let stdoutReader = LineBuffer { onLine($0, false) }
            let stderrReader = LineBuffer { onLine($0, true) }
            stdout.fileHandleForReading.readabilityHandler = { stdoutReader.append($0.availableData) }
            stderr.fileHandleForReading.readabilityHandler = { stderrReader.append($0.availableData) }

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                stdoutReader.append(stdout.fileHandleForReading.readDataToEndOfFile())
                stderrReader.append(stderr.fileHandleForReading.readDataToEndOfFile())
                stdoutReader.finish()
                stderrReader.finish()
                self.lock.lock()
                if self.process === process { self.process = nil }
                self.lock.unlock()
                continuation.resume(returning: process.terminationStatus)
            }

            self.lock.lock()
            self.process = process
            self.lock.unlock()
            do {
                try process.run()
            } catch {
                self.lock.lock()
                self.process = nil
                self.lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    private func copyScripts(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let names = ["package.json", "package-lock.json", "optimize.mjs", "convert.mjs", "preview.mjs", "selftest.mjs"]
        for name in names {
            let sourceFile = source.appendingPathComponent(name)
            guard manager.fileExists(atPath: sourceFile.path) else { continue }
            let destinationFile = destination.appendingPathComponent(name)
            if manager.fileExists(atPath: destinationFile.path) {
                try manager.removeItem(at: destinationFile)
            }
            try manager.copyItem(at: sourceFile, to: destinationFile)
        }
        let sourceLib = source.appendingPathComponent("lib", isDirectory: true)
        let destinationLib = destination.appendingPathComponent("lib", isDirectory: true)
        if manager.fileExists(atPath: destinationLib.path) {
            try manager.removeItem(at: destinationLib)
        }
        if manager.fileExists(atPath: sourceLib.path) {
            try manager.copyItem(at: sourceLib, to: destinationLib)
        }
    }
}

private final class LineBuffer {
    private let lock = NSLock()
    private var pending = Data()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            let lineData = pending.prefix(upTo: newline)
            pending.removeSubrange(...newline)
            if let text = String(data: lineData, encoding: .utf8) {
                lines.append(text.trimmingCharacters(in: .newlines))
            }
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func finish() {
        lock.lock()
        let leftover = pending
        pending.removeAll()
        lock.unlock()
        if let text = String(data: leftover, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            onLine(text)
        }
    }
}

private struct OptimizePayload: Encodable {
    var input: String
    var output: String
    var compatibility: String
    var dedup: Bool
    var instance: Bool
    var prune: Bool
    var weld: Bool
    var resample: Bool
    var sparse: Bool
    var simplify: Bool
    var simplifyRatio: Double
    var simplifyError: Double
    var simplifyLockBorder: Bool
    var geometry: String
    var meshoptLevel: String
    var dracoEncodeSpeed: Int
    var dracoPositionBits: Int
    var dracoNormalBits: Int
    var dracoTexcoordBits: Int
    var texture: TexturePayload

    init(settings: OptimizeSettings, input: URL, output: URL) {
        self.input = input.path
        self.output = output.path
        compatibility = settings.appleCompatible ? "apple" : "web"
        dedup = settings.dedup
        instance = settings.instance
        prune = settings.prune
        weld = settings.weld
        resample = settings.resample
        sparse = settings.sparse
        simplify = settings.simplify
        simplifyRatio = settings.simplifyRatio
        simplifyError = settings.simplifyError
        simplifyLockBorder = true
        geometry = settings.geometry.rawValue
        meshoptLevel = settings.meshoptLevel.rawValue
        dracoEncodeSpeed = settings.dracoEncodeSpeed
        dracoPositionBits = settings.dracoPositionBits
        dracoNormalBits = settings.dracoNormalBits
        dracoTexcoordBits = settings.dracoTexcoordBits
        texture = TexturePayload(settings: settings)
    }
}

private struct TexturePayload: Encodable {
    var format: String
    var maxSize: Int
    var quality: Int

    init(settings: OptimizeSettings) {
        format = settings.textureFormat.rawValue
        maxSize = settings.textureMaxSize
        quality = settings.textureQuality
    }
}

private struct PreviewPayload: Encodable {
    var input: String
    var output: String
    var maxTriangles: Int
    var maxTextureSize: Int
}

private struct ConvertPayload: Encodable {
    var input: String
    var output: String
    var target: String
    var unit: String
    var scale: Double
    var center: Bool
    var weld: Bool

    init(settings: ConvertSettings, input: URL, output: URL) {
        self.input = input.path
        self.output = output.path
        target = settings.target.rawValue
        unit = settings.unit.rawValue
        scale = settings.scale
        center = settings.center
        weld = settings.weld
    }
}
