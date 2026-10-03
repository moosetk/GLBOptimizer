import GLBCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var importerPresented = false

    private var importTypes: [UTType] {
        ["glb", "gltf", "stl", "obj"].compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            HSplitView {
                FileSidebarView(importerPresented: $importerPresented)
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 380)
                PreviewPane()
                    .frame(minWidth: 320)
                OptionsPanel()
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
            LogConsoleView()
                .frame(height: 168)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.refreshToolchain()
            let launchFiles = CommandLine.arguments.dropFirst()
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }
            model.addFiles(Array(launchFiles))
        }
        .onDisappear { model.persistSettings() }
        .fileImporter(isPresented: $importerPresented, allowedContentTypes: importTypes.isEmpty ? [.data] : importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                model.addFiles(urls)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $model.isTargeted) { providers in
            loadDropped(providers)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label(statusText, systemImage: statusSymbol)
                .foregroundStyle(model.toolchain.isReady ? Color.primary : Color.orange)
            Spacer()
            if model.isInstalling {
                ProgressView().controlSize(.small)
                Text("正在安装依赖")
                    .foregroundStyle(.secondary)
            } else if case .needsInstall = model.toolchain {
                Button("安装优化引擎") { model.installToolchain() }
            } else if case .missingNode = model.toolchain {
                Button("重新检测") { model.refreshToolchain() }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusText: String {
        switch model.toolchain {
        case .checking: return "正在检查本机工具链"
        case .ready: return "本地处理，不会上传文件"
        case .missingNode: return "缺少 Node.js。终端执行：brew install node"
        case .needsInstall: return "Node.js 已找到，还差一次依赖安装"
        case .failed(let message): return message
        }
    }

    private var statusSymbol: String {
        model.toolchain.isReady ? "checkmark.shield" : "exclamationmark.triangle"
    }

    private func loadDropped(_ providers: [NSItemProvider]) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                guard let url = object else { return }
                Task { @MainActor in
                    model.addFiles([url])
                }
            }
        }
        return true
    }
}
