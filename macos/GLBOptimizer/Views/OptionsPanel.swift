import SwiftUI

struct OptionsPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("模式", selection: $model.mode) {
                    ForEach(WorkMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isRunning)

                if model.mode == .optimize {
                    optimizeControls
                } else {
                    convertControls
                }

                outputControls
                actionControls
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: model.optimizeSettings) { _ in model.persistSettings() }
        .onChange(of: model.convertSettings) { _ in model.persistSettings() }
    }

    private var optimizeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("预设", selection: presetBinding) {
                ForEach(OptimizePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            Text(model.optimizeSettings.preset.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("兼容 macOS 预览 / Quick Look", isOn: edit(\.appleCompatible))

            if model.optimizeSettings.appleCompatible {
                Text("不压缩几何，纹理转成 JPEG（带透明的用 PNG）。想继续变小，就提高网格简化程度。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("几何压缩", selection: geometryBinding) {
                    ForEach(GeometryCompression.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                if model.optimizeSettings.geometry == .meshopt {
                    Picker("Meshopt 级别", selection: meshoptBinding) {
                        ForEach(MeshoptLevelChoice.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                }
                if model.optimizeSettings.geometry == .draco {
                    Stepper("位置量化 \(model.optimizeSettings.dracoPositionBits) bit", value: dracoBitsBinding, in: 10...16)
                }

                Picker("纹理格式", selection: textureFormatBinding) {
                    ForEach(TextureFormatChoice.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                if model.optimizeSettings.textureFormat == .ktx2 {
                    Text("KTX2 需要本机已安装 toktx：brew install ktx-software")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Picker("纹理最大边长", selection: textureSizeBinding) {
                Text("不缩放").tag(0)
                Text("512").tag(512)
                Text("1024").tag(1024)
                Text("2048").tag(2048)
                Text("4096").tag(4096)
            }
            VStack(alignment: .leading) {
                Text("纹理质量 \(model.optimizeSettings.textureQuality)")
                Slider(value: qualityBinding, in: 40...100, step: 1)
            }

            Toggle("简化网格", isOn: simplifyBinding)
            if model.optimizeSettings.simplify {
                VStack(alignment: .leading) {
                    Text("保留约 \(Int(model.optimizeSettings.simplifyRatio * 100))% 顶点")
                    Slider(value: ratioBinding, in: 0.1...1, step: 0.05)
                    Text("允许误差 \(model.optimizeSettings.simplifyError, format: .number.precision(.fractionLength(3)))（相对模型半径）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: errorBinding, in: 0.001...0.05, step: 0.001)
                }
            }

            DisclosureGroup("清理选项") {
                Toggle("去重", isOn: edit(\.dedup))
                Toggle("移除未使用数据", isOn: edit(\.prune))
                Toggle("焊接相同顶点", isOn: edit(\.weld))
                Toggle("重采样动画", isOn: edit(\.resample))
                Toggle("稀疏访问器", isOn: edit(\.sparse))
                Toggle("合并重复实例", isOn: edit(\.instance))
            }
        }
    }

    private var convertControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("目标格式", selection: $model.convertSettings.target) {
                ForEach(ConvertTarget.allCases) { target in
                    Text(target.title).tag(target)
                }
            }
            Text(convertHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("长度单位", selection: $model.convertSettings.unit) {
                ForEach(LengthUnit.allCases) { unit in
                    Text(unit.title).tag(unit)
                }
            }
            HStack {
                Text("缩放倍率")
                TextField("1", value: $model.convertSettings.scale, format: .number)
                    .frame(width: 80)
            }
            Toggle("居中到原点", isOn: $model.convertSettings.center)
            Toggle("焊接顶点，尽量减少缝隙", isOn: $model.convertSettings.weld)
        }
    }

    private var convertHelp: String {
        switch model.convertSettings.target {
        case .stl:
            return "导出二进制 STL，只保留几何。glTF 以米存储，这里会换算成所选单位。焊接可以减少重叠顶点造成的缝，但不能保证填补缺口。"
        case .obj:
            return "导出 OBJ 顶点和面，不写材质。单位换算与 STL 相同。"
        case .gltf:
            return "写成 JSON glTF，贴图和缓冲会拆成旁边的文件。单位菜单不参与这次转换。"
        case .glb:
            return "GLB/glTF 会重新打包。STL 和 OBJ 会按所选单位换算成 glTF 的米。"
        }
    }

    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("输出文件夹")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.outputDirectory.path)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
            HStack {
                Button("更改") { model.chooseOutputDirectory() }
                    .disabled(model.isRunning)
                Button("打开") { model.openOutputDirectory() }
            }
        }
    }

    private var actionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.isRunning {
                    Button("取消") { model.cancel() }
                } else {
                    Button(model.mode == .optimize ? "开始优化" : "开始转换") { model.start() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.toolchain.isReady || model.files.isEmpty)
                }
            }
            ProgressView(value: model.progress) {
                Text(model.progressLabel)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
    }

    private var presetBinding: Binding<OptimizePreset> {
        Binding(
            get: { model.optimizeSettings.preset },
            set: { model.optimizeSettings.apply($0) }
        )
    }

    private var geometryBinding: Binding<GeometryCompression> {
        Binding(
            get: { model.optimizeSettings.geometry },
            set: { newValue in model.optimizeSettings.edit { $0.geometry = newValue } }
        )
    }

    private var meshoptBinding: Binding<MeshoptLevelChoice> {
        Binding(
            get: { model.optimizeSettings.meshoptLevel },
            set: { newValue in model.optimizeSettings.edit { $0.meshoptLevel = newValue } }
        )
    }

    private var dracoBitsBinding: Binding<Int> {
        Binding(
            get: { model.optimizeSettings.dracoPositionBits },
            set: { newValue in model.optimizeSettings.edit { $0.dracoPositionBits = newValue } }
        )
    }

    private var textureFormatBinding: Binding<TextureFormatChoice> {
        Binding(
            get: { model.optimizeSettings.textureFormat },
            set: { newValue in model.optimizeSettings.edit { $0.textureFormat = newValue } }
        )
    }

    private var textureSizeBinding: Binding<Int> {
        Binding(
            get: { model.optimizeSettings.textureMaxSize },
            set: { newValue in model.optimizeSettings.edit { $0.textureMaxSize = newValue } }
        )
    }

    private var qualityBinding: Binding<Double> {
        Binding(
            get: { Double(model.optimizeSettings.textureQuality) },
            set: { newValue in model.optimizeSettings.edit { $0.textureQuality = Int(newValue) } }
        )
    }

    private var simplifyBinding: Binding<Bool> {
        Binding(
            get: { model.optimizeSettings.simplify },
            set: { newValue in model.optimizeSettings.edit { $0.simplify = newValue } }
        )
    }

    private var ratioBinding: Binding<Double> {
        Binding(
            get: { model.optimizeSettings.simplifyRatio },
            set: { newValue in model.optimizeSettings.edit { $0.simplifyRatio = newValue } }
        )
    }

    private var errorBinding: Binding<Double> {
        Binding(
            get: { model.optimizeSettings.simplifyError },
            set: { newValue in model.optimizeSettings.edit { $0.simplifyError = newValue } }
        )
    }

    private func edit(_ keyPath: WritableKeyPath<OptimizeSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.optimizeSettings[keyPath: keyPath] },
            set: { newValue in model.optimizeSettings.edit { $0[keyPath: keyPath] = newValue } }
        )
    }
}
