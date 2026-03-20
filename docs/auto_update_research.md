# Snipshot 自动更新方案调研报告

## 背景与现状分析

在为 Snipshot 引入自动更新机制之前，我们需要先明确项目当前的架构特点。Snipshot 是一个使用 `swiftc` 命令行直接编译的 macOS 原生应用，没有使用 Xcode 工程文件，也没有引入 Swift Package Manager (SPM) 或 Carthage 等包管理工具。

在分发和签名方面，项目目前支持两种模式：开发模式下使用自签名的 "Snipshot Dev" 证书，生产模式下使用 Apple Developer ID 证书并进行公证，打包为 DMG 格式分发。此外，应用是非沙盒化的（`app-sandbox` 为 false）。

基于这些技术特点，我调研了目前 macOS 生态中主流的自动更新方案，并针对 Snipshot 的具体情况进行了可行性分析。

## 可选方案对比

### 1. Sparkle 框架（业界标准）

Sparkle 是 macOS 生态中最流行、最成熟的开源自动更新框架 [1]。它通过解析服务器上的 Appcast（RSS 格式的更新源）来发现新版本，并支持静默下载、增量更新和自动重启。

**优势：**
框架非常成熟，经过了大量知名应用的验证。它不仅支持标准的 Apple Developer ID 签名，也完全支持自签名应用的更新验证。Sparkle 使用了独立的 EdDSA (ed25519) 签名机制来确保更新包的安全性，这意味着即使是没有 Apple 开发者账号的自签名应用，也能安全地分发更新 [2]。此外，它提供了纯代码初始化的方式（Programmatic Setup），无需依赖 XIB 文件 [3]。

**挑战：**
由于 Snipshot 使用 `swiftc` 命令行编译，集成 Sparkle 会比在 Xcode 中复杂。我们需要手动下载预编译的 `Sparkle.framework`，在编译时添加 `-F` 搜索路径和 `-framework Sparkle` 链接参数，设置正确的 RPATH（`-Wl,-rpath,@loader_path/../Frameworks`），并在打包脚本中手动将框架复制到 `.app/Contents/Frameworks/` 目录下 [4]。

### 2. 基于 GitHub Releases 的轻量级更新器（如 s1ntoneli/AppUpdater）

这类方案专门针对开源或使用 GitHub 分发的应用设计，直接通过 GitHub API 检查 Releases 中的二进制产物进行更新 [5]。`s1ntoneli/AppUpdater` 是对早期知名库 `mxcl/AppUpdater` 的现代化重写，使用了 Swift 的 `async/await` 特性。

**优势：**
使用极其简单，只需要提供 GitHub 的 Owner 和 Repo 名称即可。它原生支持非沙盒应用，并且内置了对拉取进度、解压和替换应用逻辑的封装。它还会在更新前校验下载包的代码签名标识是否与当前运行的应用一致，提供了一定的安全性。

**挑战：**
该库是以 Swift Package 形式提供的。由于 Snipshot 没有使用 SPM，如果采用此方案，我们要么需要将项目的构建方式迁移到 SPM，要么需要将该库的源码直接 Vendor（复制）到我们的代码库中。此外，它强依赖于 GitHub Releases 作为分发渠道，不够灵活。

### 3. 完全自研更新逻辑

利用 Swift 原生的 `URLSession` 和系统 API，我们可以自己实现一套简单的自动更新机制。

**优势：**
完全没有外部依赖，不需要处理复杂的 Framework 嵌入或包管理器配置。我们可以完全控制更新流程、UI 展现和版本检查逻辑，保持应用的极致轻量。

**挑战：**
需要自己处理很多边缘情况，例如下载过程的错误处理、ZIP/DMG 文件的解压、原子化替换当前正在运行的 `.app` 目录、以及安全校验（防止中间人攻击篡改更新包）。如果处理不当，容易导致应用损坏或引发安全漏洞。

### 4. Squirrel.Mac

Squirrel 是 Electron 应用（如 Slack、Discord 等）广泛使用的更新框架，采用服务器驱动的更新模式 [6]。

**评估：**
Squirrel 依赖于后端的特定接口支持，并且主要使用 Objective-C 编写，依赖了 ReactiveCocoa 和 Mantle 等较重的库 [7]。对于 Snipshot 这样一个轻量级的原生 Swift 应用来说，引入 Squirrel 显得过于沉重且不合适，因此不建议考虑。

## 综合评估与建议

| 方案 | 成熟度 | 安全性 | 集成难度（基于 swiftc） | 推荐度 |
| :--- | :--- | :--- | :--- | :--- |
| **Sparkle** | 极高 | 极高（EdDSA 签名） | 中等偏上（需修改 build.sh） | ⭐⭐⭐⭐ |
| **AppUpdater (GitHub)** | 中等 | 中等（校验签名 ID） | 高（需引入 SPM 或拷贝源码） | ⭐⭐⭐ |
| **自研更新逻辑** | 视实现而定 | 视实现而定 | 低（纯 Swift 代码） | ⭐⭐ |
| **Squirrel.Mac** | 高 | 高 | 极高（依赖过多） | ⭐ |

**推荐方案：Sparkle**

尽管在 `swiftc` 环境下集成 Sparkle 需要对现有的 `build.sh` 脚本进行一些改造，但从长远来看，Sparkle 是最稳妥的选择。它不仅完美支持自签名应用（通过其独立的 EdDSA 签名机制），而且处理了诸如权限提升、文件替换、版本对比等所有复杂的底层细节。

### 实施路径建议（基于 Sparkle）

如果决定采用 Sparkle，我们可以按照以下步骤在 `build.sh` 中进行集成：

1. **下载预编译框架**：在构建脚本中下载 Sparkle 的 Release 压缩包，提取 `Sparkle.framework`。
2. **生成密钥**：运行 Sparkle 提供的 `./bin/generate_keys` 工具，生成一对 EdDSA 密钥，将公钥添加到 `Info.plist` 中。
3. **调整编译参数**：修改 `swiftc` 命令，增加 `-F <框架路径> -framework Sparkle -Wl,-rpath,@loader_path/../Frameworks`。
4. **打包处理**：在组装 `.app` 目录时，创建 `Contents/Frameworks` 文件夹，将 `Sparkle.framework` 复制进去。
5. **代码集成**：在 `AppDelegate` 中使用 `SPUStandardUpdaterController` 进行纯代码初始化。
6. **分发准备**：使用 Sparkle 的 `generate_appcast` 工具为打包好的 DMG 生成更新信息，并上传到服务器。

通过这种方式，Snipshot 既能保持现有的命令行构建流程，又能获得业界最强大的自动更新能力。

## 参考文献

[1] Sparkle Project. (n.d.). Sparkle: open source software update framework for macOS. https://sparkle-project.org/
[2] Sparkle Project. (n.d.). Documentation - Basic Setup. https://sparkle-project.org/documentation/
[3] Sparkle Project. (n.d.). Setting up Sparkle programmatically. https://sparkle-project.org/documentation/programmatic-setup/
[4] Steinberger, P. (2025). Code Signing and Notarization: Sparkle and Tears. https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears
[5] s1ntoneli. (n.d.). AppUpdater: A simple app-updater for macOS. GitHub. https://github.com/s1ntoneli/AppUpdater
[6] Squirrel. (n.d.). Squirrel.Mac. GitHub. https://github.com/squirrel/squirrel.mac
[7] Heresy Dev. (2016). Auto-updating apps for Windows and OSX using Electron. Medium. https://medium.com/heresy-dev/auto-updating-apps-for-windows-and-osx-using-electron-the-complete-guide-4aa7a50b904c
