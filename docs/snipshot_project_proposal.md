# Snipshot 项目建议书 (v2.1 - MVP 已实现)

## 1. 引言

根据最新项目要求，Snipshot 将定位为一款 **macOS 专属** 的桌面截图与贴图工具，旨在充分利用苹果原生技术，提供极致的性能和无缝的系统集成体验。项目的设计灵感来源于 Snipaste [1]，但将专注于为 Mac 用户打造一个更现代化、更高效的替代方案。

本文档基于 v2 版本进行更新，反映了当前 MVP (Minimum Viable Product) 的已实现状态，并移除了部分尚未实现的功能规划，使其更贴近项目现状。

## 2. 已实现核心功能 (MVP)

Snipshot 的 MVP 版本已完成，核心功能围绕“截图（Snip）”、“贴图（Paste）”和“图像标注（Annotate）”三大模块构建。

| 功能模块 | 已实现功能点 |
| :--- | :--- |
| **截图 (Snip)** | - **全局快捷键**：支持 F1 唤起截图，F3 从剪贴板贴图。<br>- **自定义区域截图**：通过拖拽鼠标进行自由区域选择。<br>- **像素级控制**：选区后可通过键盘方向键进行 1px 微调，Shift + 方向键进行 10px 调整。<br>- **可交互选区**：选区完成后，可通过拖拽移动选区位置，或通过 8 个手柄调整选区大小。<br>- **多种输出方式**：支持将截图复制到剪贴板、保存为文件或直接 Pin 为置顶窗口。 |
| **贴图 (Paste)** | - **剪贴板内容贴图**：按 F3 可将剪贴板中的图像作为置顶窗口贴在屏幕上。<br>- **丰富的窗口操作**：支持对贴图进行拖拽移动、鼠标滚轮缩放、ESC 键关闭。 |
| **图像标注 (Annotate)** | - **基础标注工具**：提供箭头、矩形、文字、序号标记、马赛克工具。<br>- **参数调整**：支持修改颜色和笔画粗细（通过滚轮或 +/- 按钮）。<br>- **可交互标注**：所有标注元素均可选中、拖拽移动、调整大小和删除。 |

## 3. 技术选型 (已采用)

项目完全采用苹果原生技术栈进行开发，确保了最佳性能和系统集成度。

| 功能模块 | 已采用 API / 框架 |
| :--- | :--- |
| **应用框架** | **AppKit**：使用纯 AppKit 构建应用，确保了对底层窗口和事件的完全控制。 |
| **屏幕捕捉** | **ScreenCaptureKit** [2]：采用苹果现代化的屏幕捕捉框架，实现了高效的全屏内容获取。 |
| **全局快捷键** | **CGEventTap**：通过 `CGEvent.tapCreate` 监听全局键盘事件，实现了 F1 和 F3 的快捷键绑定。 |
| **贴图窗口** | **AppKit (NSWindow)**：通过创建无边框、置顶的 `NSWindow` (`PinWindow`) 来实现贴图功能。 |
| **图像标注** | **Core Graphics**：在 `OverlayView` 中使用 `Core Graphics` API 实现所有标注元素的绘制、选中和交互逻辑。 |
| **代码签名** | **自签名证书**：通过创建本地自签名证书（"Snipshot Dev"）解决了 TCC 权限在重编译后反复弹窗的问题。 |

## 4. 后续发展方向 (v2 规划)

在当前 MVP 的基础上，后续版本可继续推进 v2 提案中的高级功能。

- **OCR (Live Text)**：利用 `VisionKit` 实现截图后的“实况文本”交互 [3]。
- **智能窗口/UI元素检测**：通过 `Accessibility API` 实现窗口和控件边界的自动检测 [4]。
- **快捷键自定义**：提供设置界面，允许用户自定义所有功能的快捷键。

---

### 参考文献

[1] Snipaste. (2026). *Snipaste Official Website*. Retrieved from https://www.snipaste.com/
[2] Apple Inc. (2026). *ScreenCaptureKit*. Apple Developer Documentation. Retrieved from https://developer.apple.com/documentation/screencapturekit/
[3] Apple Inc. (2026). *Enabling Live Text interactions with images*. Apple Developer Documentation. Retrieved from https://developer.apple.com/documentation/visionkit/enabling-live-text-interactions-with-images
[4] Apple Inc. (2026). *Accessibility*. Apple Developer Documentation. Retrieved from https://developer.apple.com/documentation/accessibility
