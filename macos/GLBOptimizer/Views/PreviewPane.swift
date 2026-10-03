import SwiftUI

struct PreviewPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("预览")
                    .font(.headline)
                if model.selectedFile?.outputURL != nil, model.selectedFile?.outputURL?.pathExtension.lowercased() == "glb" {
                    Picker("", selection: $model.previewSource) {
                        ForEach(PreviewSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                Text(model.previewMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            .padding(12)

            ZStack {
                ModelSceneView(preview: model.previewScene)
                if model.isPreviewLoading {
                    ProgressView(model.previewMessage)
                        .padding()
                } else if model.previewScene == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 42))
                            .foregroundStyle(.tertiary)
                        Text(model.previewMessage)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
