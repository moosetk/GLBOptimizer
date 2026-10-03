import GLBCore
import SwiftUI

struct FileSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var importerPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("文件")
                    .font(.headline)
                Spacer()
                Button {
                    importerPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加文件")
                Button(role: .destructive) {
                    model.removeSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(model.selection == nil || model.isRunning)
            }
            .padding(12)

            if model.files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(model.isTargeted ? "松开即可加入" : "拖入 .glb / .gltf，或点 + 添加")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(selection: $model.selection) {
                    ForEach(model.files) { file in
                        FileRow(file: file)
                            .tag(file.id)
                            .contextMenu {
                                if let output = file.outputURL {
                                    Button("在 Finder 中显示") { model.reveal(output) }
                                }
                            }
                    }
                }
                .onChange(of: model.selection) { newValue in
                    model.select(newValue)
                }
            }

            HStack {
                Button("清空") { model.removeAll() }
                    .disabled(model.files.isEmpty || model.isRunning)
                Spacer()
                Text("\(model.files.count) 个")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct FileRow: View {
    let file: SourceFile

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text(file.name)
                    .lineLimit(1)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts = [ByteFormat.string(file.byteSize)]
        if let output = file.outputBytes {
            parts.append("→ \(ByteFormat.string(output))")
        }
        if let message = file.message, file.status == .succeeded || file.status == .failed {
            parts.append(message)
        }
        if let elapsed = file.elapsed, file.status == .succeeded {
            parts.append(String(format: "%.1f 秒", elapsed))
        }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch file.status {
        case .ready: return "doc"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        }
    }

    private var color: Color {
        switch file.status {
        case .ready: return .secondary
        case .running: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}
