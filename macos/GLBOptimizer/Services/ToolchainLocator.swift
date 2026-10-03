import Foundation

enum ToolchainError: LocalizedError {
    case missingNode
    case needsInstall
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingNode:
            return "没有找到 Node.js。请先安装：brew install node"
        case .needsInstall:
            return "优化引擎还没安装。点击「安装优化引擎」即可，只需本机已有 Node.js。"
        case .commandFailed(let message):
            return message
        }
    }
}

struct ResolvedToolchain: Equatable {
    var node: URL
    var root: URL
}

enum ToolchainLocator {
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("GLBOptimizer/toolchain", isDirectory: true)
    }()

    static func resolve() -> ToolchainStatus {
        guard let node = findNode() else { return .missingNode }
        if let root = candidateRoots().first(where: hasDependencies) {
            return .ready(node: node, root: root)
        }
        if let root = candidateRoots().first(where: { fileExists($0.appendingPathComponent("package.json")) }) {
            return .needsInstall(node: node, root: root)
        }
        if let bundled = bundledScripts(), fileExists(bundled.appendingPathComponent("package.json")) {
            return .needsInstall(node: node, root: bundled)
        }
        return .failed("应用里没有找到优化脚本。请重新构建应用。")
    }

    static func findNode() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        let pathParts = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for part in pathParts {
            let candidate = URL(fileURLWithPath: String(part)).appendingPathComponent("node")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nodeFromLoginShell()
    }

    static func candidateRoots() -> [URL] {
        var roots: [URL] = []
        if let linked = linkedRepositoryRoot() { roots.append(linked) }
        if let bundled = bundledScripts() { roots.append(bundled) }
        roots.append(supportDirectory)
        return roots
    }

    static func installRoot() -> URL? {
        if let linked = linkedRepositoryRoot(), isWritable(linked) { return linked }
        return supportDirectory
    }

    static func linkedRepositoryRoot() -> URL? {
        guard let url = Bundle.main.url(forResource: "location", withExtension: "txt", subdirectory: "toolchain"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func bundledScripts() -> URL? {
        Bundle.main.url(forResource: "toolchain", withExtension: nil)
    }

    static func hasDependencies(_ root: URL) -> Bool {
        fileExists(root.appendingPathComponent("node_modules/@gltf-transform/core/package.json"))
            && fileExists(root.appendingPathComponent("optimize.mjs"))
    }

    static func enrichedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let prefixes = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/opt/homebrew/sbin"]
        let current = environment["PATH"] ?? ""
        environment["PATH"] = (prefixes + [current]).joined(separator: ":")
        return environment
    }

    private static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func isWritable(_ url: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: url.path)
    }

    private static func nodeFromLoginShell() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
