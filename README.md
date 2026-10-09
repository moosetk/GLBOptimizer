# GLB 优化器

本地 macOS 工具，用来把很大的 AI 生成 `.glb` 压到适合网页的体积，也可以把模型转成二进制 STL 等格式。文件不会上传。

## 架构

界面是 SwiftUI 应用，优化和格式转换交给本机的 Node 工具链。这样可以直接使用 glTF-Transform 4.5（Meshopt、Draco、Sharp/WebP），行为与命令行工具一致，也方便以后加新的优化步骤。

```text
GLBOptimizer.app
  ├─ SwiftUI：文件队列、预设、SceneKit 预览、日志
  ├─ Packages/GLBCore：体积格式化等纯逻辑，供单测
  └─ Toolchain/*.mjs
       ├─ optimize.mjs   glTF-Transform：dedup / prune / weld / resample / 纹理 / Meshopt 或 Draco
       ├─ convert.mjs    GLB → STL/OBJ/glTF，以及 STL/OBJ → GLB
       └─ preview.mjs    把模型解码成 SceneKit 能读的预览副本
```

预览用 SceneKit 原生渲染，带 PBR 材质和贴图。SceneKit 读不了 Draco、Meshopt、量化和 WebP，所以选中文件后，`preview.mjs` 会先把模型解码成一份临时预览 GLB（超过 200 万面时简化，纹理最大 2048）。这一步大约需要几秒，原始文件不会被改动。处理完成后可以在预览上方切换「原始 / 处理后」做对比。KTX2 纹理在预览里不显示。

## 环境

- macOS 13 或更新版本，已在 Apple Silicon 上开发
- Xcode 16 或更新版本
- Node.js 18 或更新版本（Homebrew：`brew install node`）
- 只有选用 KTX2 时才需要 `toktx`：`brew install ktx-software`

Meshopt、Draco 和 WebP/JPEG/PNG 都随 `npm install` 安装，不需要额外的系统库。

## 开始使用

```bash
sh scripts/setup-toolchain.sh
open macos/GLBOptimizer.xcodeproj
```

在 Xcode 里选择 `GLBOptimizer` scheme，运行。应用会在构建时把工具链脚本拷进 app，并通过 `location.txt` 找到仓库里的 `Toolchain/`（里面已经有 `node_modules`）。

如果本机有 Node、但依赖还没装，窗口顶部会出现「安装优化引擎」。它会在仓库的 `Toolchain/`（可写时）或 `~/Library/Application Support/GLBOptimizer/toolchain` 里执行 `npm install`。

命令行自测：

```bash
node Toolchain/selftest.mjs
swift test --package-path Packages/GLBCore
xcodebuild -project macos/GLBOptimizer.xcodeproj -scheme GLBOptimizer -destination 'platform=macOS' -derivedDataPath macos/build CODE_SIGNING_ALLOWED=NO build
```

## 打包成可安装的 app

```bash
sh scripts/build-release.sh
```

会生成 `dist/GLBOptimizer.app` 和 `dist/GLBOptimizer.dmg`。Release 版把 glTF-Transform 依赖打进了 app，安装后不用再执行 `npm install`，但目标机器仍需要 Node.js。

默认是 ad-hoc 签名。拷到别的 Mac 上第一次打开时，需要右键「打开」，或执行 `xattr -dr com.apple.quarantine /Applications/GLBOptimizer.app`。要正常分发，用 `SIGN_IDENTITY="Developer ID Application: …" sh scripts/build-release.sh` 签名，再用 `xcrun notarytool` 公证 DMG。

## 优化预设

| 预设 | 行为 |
| --- | --- |
| Web 推荐 | Meshopt + 最长边 1024 的 WebP，质量 80。不去简化网格。 |
| 最大压缩 | Draco（更低的位置量化）+ 512px WebP，质量 60，并简化网格。 |
| 高质量 | Meshopt + 2048px WebP，质量 92。不简化。 |
| macOS 兼容 | 不压缩几何，JPEG 纹理（带透明用 PNG），网格简化到约 25%。macOS 预览和 Quick Look 能打开。 |
| 自定义 | 可调纹理边长、格式、质量、Draco 量化、是否简化、焊接和动画重采样。 |

默认还会做去重、裁剪未使用数据、焊接完全相同的顶点、动画关键帧重采样。单色贴图会被收成材质颜色，这是体积优化的一部分。

输出文件写到所选文件夹，文件名是 `<原名>.optimized.glb`，不会覆盖源文件。体积对比和耗时显示在列表和日志里。

对网页加载来说，Meshopt 通常比 Draco 更合适。Draco 往往更小，但浏览器端解码更重。KTX2 体积和 GPU 占用都不错，查看器需要支持 `KHR_texture_basisu`。

把约 100MB 的模型降到原来的 5%–20%，主要靠缩小并重编码贴图。如果体积主要来自很高的面数，用「最大压缩」或自定义里的网格简化。

## 格式转换

| 方向 | 说明 |
| --- | --- |
| GLB/glTF → STL | 二进制 STL。只保留几何，材质、贴图、动画会丢掉。 |
| GLB/glTF → OBJ | 顶点和面。 |
| GLB → glTF | JSON 加外部缓冲和贴图。 |
| GLB/glTF/STL/OBJ → GLB | STL、OBJ 会按所选单位换算成 glTF 的米。 |

glTF 的长度单位是米。导出 STL/OBJ 时，「毫米」会乘 1000，这是 3D 打印里常见的做法。STL 转回 GLB 时，按你选择的源单位除回米。

转换会把节点变换烘焙进顶点，导出默认姿势。有蒙皮时不会做骨骼形变。开启「焊接顶点」会把非常靠近的点合成一个，减少缝隙；缺口本身不会被补上，所以不能保证一定是水密网格。

## 目录

```text
macos/GLBOptimizer.xcodeproj   应用工程
macos/GLBOptimizer/            SwiftUI 界面和任务队列
Packages/GLBCore/              GLB 读取、体积格式化、单元测试
Toolchain/                     glTF-Transform 脚本和 package.json
scripts/setup-toolchain.sh     安装 Node 依赖
```

## 常见问题

**提示找不到 Node.js**  
从终端启动能找到、但从 Finder 找不到时，程序仍会查找 `/opt/homebrew/bin/node` 和 `/usr/local/bin/node`。用 nvm 时先执行 `brew install node`，或在登录 shell 里保证 `node` 可用后点击「重新检测」。

**优化失败，提示文件损坏或不支持的扩展**  
用其他工具打开同一个 GLB，确认它本身能读。日志里会保留引擎的原文信息。

**优化后的 GLB 用 macOS 预览打不开**  
Web 预设会把 Meshopt/Draco 和 WebP 写成必需扩展，macOS 预览不支持它们，但浏览器里的 three.js、Babylon.js、model-viewer 都支持。需要在 Finder 里预览或发给 Mac 用户时，改用「macOS 兼容」预设。没有几何压缩时，面数决定体积，所以这个预设会简化网格。

**KTX2 失败**  
安装 `brew install ktx-software` 后重试。没有 `toktx` 时选 WebP 或 JPEG。

**预览一直显示「正在生成预览」**  
预览依赖优化引擎（Node 工具链）。窗口顶部显示引擎未就绪时，先按提示安装；失败原因会写在下方日志里。

**处理很慢或内存升高**  
一张 8K 贴图解码后会占用很多内存。先把最大边长降到 1024 或 512。队列是一个一个处理的。

**想在命令行跑同一条管线**  
应用写的是临时 JSON 任务，再调用 `node Toolchain/optimize.mjs <job.json>`。任务字段与界面上的预设一致，见 `Toolchain/optimize.mjs` 开头读入的字段。
