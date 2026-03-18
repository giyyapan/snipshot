# 截图软件窗口吸附与重叠处理机制调研报告

**作者**: Manus AI
**日期**: 2026年3月17日

## 摘要

在截图软件（如 Snipshot）中实现智能的“窗口吸附”功能时，处理重叠窗口（Overlapping Windows）是一个核心技术挑战。当多个窗口层叠时，简单的“鼠标所在位置的窗口”检测往往不够智能，尤其是对于被部分或完全遮挡的底层窗口。

本报告深入调研了 macOS 原生截图、Snipaste、ShareX、Flameshot 以及 Chromium 浏览器等主流软件和项目的窗口检测与遮挡计算逻辑。研究发现，不同操作系统底层架构的差异决定了最佳实践的不同。特别是在 macOS 环境下，由于窗口服务器（Window Server）维护了所有窗口的完整渲染缓冲区，即使是被完全遮挡的窗口也能被完整截图。因此，macOS 下的最佳实践是**允许吸附到任何具有可见区域的窗口，并捕获其完整内容**。

## 1. 行业主流截图工具的处理机制

通过对多款主流截图工具的调研，我们发现它们在处理窗口吸附和重叠时采用了不同的策略。

### 1.1 macOS 原生截图 (Cmd+Shift+4+Space)

macOS 的原生截图工具在处理窗口吸附时表现出极高的宽容度。当用户进入窗口捕获模式时，系统会高亮显示鼠标当前悬停的**最顶层窗口**。

然而，更深层次的机制在于其底层 API `CGWindowListCreateImage` 的使用。当用户选择了一个被其他窗口部分遮挡的底层窗口时，macOS 原生截图**能够捕获该底层窗口的完整内容**，而不仅仅是其可见部分 [1]。这是因为 macOS 的窗口合成器（Compositor）独立维护了每个窗口的完整图像缓冲区。

因此，macOS 原生截图的逻辑是：只要用户能够通过某种方式（如触及未被遮挡的边缘）将鼠标悬停在目标窗口上，系统就会高亮显示该窗口的完整边界，并最终捕获其完整、无遮挡的图像。

### 1.2 Snipaste 的智能 UI 元素检测

Snipaste 是一款以智能吸附著称的跨平台截图工具。根据其官方技术解析，Snipaste 采用了基于系统句柄（Handle）和无障碍 API（Accessibility API）的深度检测机制 [2]。

在处理复杂窗口堆叠时，Snipaste 的智能识别能够“穿透”顶层窗口的遮挡。其核心逻辑如下：
当鼠标悬停在屏幕某处时，Snipaste 会通过系统 API 查询该坐标下所有堆叠的窗口（基于 Z-order）。只要底层窗口有任何**可见部分**能够被鼠标触及，Snipaste 就能识别出该窗口的完整边界并进行高亮吸附。在实际截图时，它同样会捕获该窗口的完整内容，而非被裁剪后的碎片。

### 1.3 ShareX 与 Flameshot 的实现方案

ShareX（Windows 平台）通过调用 Win32 API `EnumWindows` 获取所有顶级窗口，并根据 Z-order（从前到后）构建一个窗口矩形列表。当鼠标移动时，它会遍历该列表，找到第一个包含鼠标坐标的窗口矩形（即最顶层窗口）进行吸附 [3]。

Flameshot（Linux 平台）的实现则受限于显示服务器协议。在 X11 环境下，它依赖 `xdotool` 获取窗口几何信息；而在 Wayland 环境下，由于协议安全性限制，无法直接获取全局窗口位置，导致窗口吸附功能受限 [4]。Flameshot 社区曾讨论过使用纯图像识别（形状检测）来寻找窗口边界，但因无法完美处理透明度、圆角和阴影而被否决。

### 1.4 工具机制对比总结

| 工具名称 | 操作系统 | 窗口检测技术栈 | 遮挡处理逻辑（吸附与捕获） |
|---------|---------|--------------|------------------------|
| macOS 原生 | macOS | Core Graphics (`CGWindowListCopyWindowInfo`) | 吸附最顶层；可捕获被遮挡窗口的完整内容 |
| Snipaste | Win/Mac | Window Handles / Accessibility API | 只要有可见区域即可吸附；捕获完整内容 |
| ShareX | Windows | Win32 `EnumWindows` | 基于 Z-order 匹配最顶层窗口 |
| Flameshot | Linux | `xdotool` (X11) | 获取窗口几何坐标进行区域框选 |

## 2. 窗口可见性与遮挡计算的核心算法

如果我们要实现更高级的逻辑（例如：只吸附“可见面积大于 50%”的窗口），我们需要计算窗口的实际可见区域。Chromium 浏览器开源项目中的“原生窗口遮挡追踪器”（Native Window Occlusion Tracker）提供了一个极其经典的工业级算法实现 [5]。

### 2.1 Chromium 的矩形相减算法 (Rectangle Subtraction)

Chromium 为了优化性能，需要精确计算哪些浏览器窗口被其他应用程序窗口完全遮挡。其算法巧妙地利用了区域（Region）的布尔运算，核心步骤如下：

1. **初始化未遮挡区域**：创建一个代表整个虚拟屏幕（包含所有显示器）的矩形区域，记为 `unoccluded_desktop_region`。
2. **按 Z-order 遍历**：从最顶层（Front）到最底层（Back）遍历所有系统窗口。
3. **过滤无效遮挡物**：忽略最小化、完全透明、异形或属于其他虚拟桌面的窗口，以防止产生“假阳性”（误判可见窗口为被遮挡）。
4. **区域相减**：对于每一个遍历到的窗口：
   - 如果它是目标窗口：记录当前的 `unoccluded_desktop_region`。将目标窗口的矩形从该区域中减去（使用 `kDifference_Op`）。如果减去前后，`unoccluded_desktop_region` **没有发生任何变化**，说明该目标窗口的所在位置已经被之前（更高层）的窗口完全挖空了，即该窗口被**完全遮挡 (Occluded)**。如果区域发生了变化，说明它至少有一部分是可见的。
   - 如果它是其他窗口：直接将其矩形区域从 `unoccluded_desktop_region` 中减去，相当于在屏幕上“挖掉”了一块。

这个算法的优雅之处在于，它不需要计算复杂的多边形交集，而是通过维护一个“剩余可见屏幕区域”，不断从中减去顶层窗口，从而高效地判断底层窗口的可见性。

## 3. macOS 平台的技术实现路径

对于在 macOS 上开发的 Snipshot 项目，系统提供了强大的 API 支持来实现智能窗口吸附。

### 3.1 窗口信息获取：CGWindowListCopyWindowInfo

这是 macOS 上获取窗口列表最核心的 API。调用 `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)` 可以返回当前屏幕上所有窗口的详细信息数组 [6]。

该数组默认是**严格按照 Z-order（从前到后）排序**的。每个窗口字典中包含了关键信息：
- `kCGWindowNumber`: 窗口的唯一 ID
- `kCGWindowBounds`: 窗口在屏幕上的矩形坐标
- `kCGWindowLayer`: 窗口层级（普通窗口通常为 0）
- `kCGWindowAlpha`: 窗口透明度

### 3.2 鼠标命中测试 (Hit-Testing)

当鼠标在屏幕上移动时，遍历上述获取到的窗口列表。由于列表已按 Z-order 排序，第一个其 `kCGWindowBounds` 包含鼠标坐标的窗口，就是当前鼠标悬停的最顶层窗口。

如果需要实现“穿透”吸附（像 Snipaste 那样），可以通过无障碍 API `AXUIElementCopyElementAtPosition` 获取鼠标位置的 UI 元素，或者在用户按住特定修饰键（如 Option）时，高亮鼠标坐标下 Z-order 次高的窗口 [7]。

### 3.3 悬停高亮与层级控制

在检测到目标窗口后，需要绘制一个高亮遮罩。为了确保高亮遮罩正确覆盖在目标窗口之上，且不遮挡更高层的窗口，可以使用 `NSWindow.order(_:relativeTo:)` 方法。

通过获取目标窗口的 `kCGWindowNumber`，执行 `highlightWindow.order(.above, relativeTo: targetWindowNumber)`，macOS 的窗口服务器会自动将高亮遮罩插入到正确的 Z-order 位置 [8]。这样，如果目标窗口被其他窗口遮挡，高亮遮罩也会被正确地遮挡，提供完美的视觉反馈。

## 4. 给 Snipshot 的最佳实践建议

基于以上调研，针对 Snipshot 的窗口自动吸附逻辑，提出以下最佳实践建议：

### 建议一：允许吸附底层窗口，并捕获完整内容

**结论**：不要因为窗口被部分遮挡就放弃吸附。在 macOS 下，被遮挡的窗口依然有截图的意义。

**理由**：macOS 的 `CGWindowListCreateImage` API 配合 `kCGWindowListOptionIncludingWindow` 选项，能够完美捕获被遮挡窗口的完整图像，连阴影都能保留 [1]。用户经常需要截取被遮挡的后台窗口，如果限制只能吸附最顶层窗口，将大大降低工具的实用性。

### 建议二：采用 Z-order 遍历 + 鼠标命中测试

**实现逻辑**：
1. 实时（或在进入截图模式时）通过 `CGWindowListCopyWindowInfo` 获取按 Z-order 排序的窗口列表。
2. 鼠标移动时，从前向后遍历列表，进行 `CGRectContainsPoint` 测试。
3. 命中的第一个窗口即为默认吸附目标。

### 建议三：引入“可见面积阈值”优化体验（进阶）

如果希望进一步提升智能化，避免吸附到只露出一两个像素边缘的“无意义”底层窗口，可以引入基于 Chromium 算法的可见面积计算：

1. 当鼠标命中某个底层窗口时，获取该窗口的完整 `Rect`。
2. 收集 Z-order 在该窗口之上的所有不透明窗口的 `Rect`。
3. 将目标窗口的 `Rect` 减去所有上层窗口的 `Rect`（可使用 Swift 中的 `NSBezierPath` 或 Core Graphics 的区域运算）。
4. 计算剩余区域的面积。如果可见面积小于目标窗口总面积的 10%（阈值可调），则认为该窗口“几乎不可见”，放弃吸附，继续向下寻找或回退到区域选择。

### 建议四：使用相对排序渲染高亮边框

在绘制吸附高亮框时，不要简单地将其置于 `NSWindow.Level.floating`（最顶层）。这会导致高亮框覆盖在实际遮挡目标窗口的其他窗口之上，视觉上非常违和。

**正确做法**：使用 `highlightWindow.order(.above, relativeTo: targetWindowNumber)`，让系统接管层级渲染，使得高亮框的遮挡关系与目标窗口完全一致 [8]。

## 参考文献

[1] Stack Overflow. "Grab a screenshot of an obscured window". https://stackoverflow.com/questions/11992369/grab-a-screenshot-of-an-obscured-window
[2] Snipaste Feedback Wiki. "Troubleshooting". https://github.com/Snipaste/feedback/wiki/troubleshooting
[3] ShareX Source Code. "WindowsRectangleList.cs". https://github.com/ShareX/ShareX/blob/master/ShareX.ScreenCaptureLib/Helpers/WindowsRectangleList.cs
[4] Flameshot GitHub Issues. "Selecting a window in GUI mode #5". https://github.com/flameshot-org/flameshot/issues/5
[5] Chromium Blog. "Chrome on Windows performance improvements and the journey of Native Window Occlusion". https://blog.chromium.org/2021/12/chrome-windows-performance-improvements-native-window-occlusion.html
[6] Apple Developer Documentation. "CGWindowListCopyWindowInfo". https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)
[7] Apple Developer Documentation. "AXUIElementCopyElementAtPosition". https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition
[8] Stack Overflow. "Highlight NSWindow under mouse cursor". https://stackoverflow.com/questions/56935106/highlight-nswindow-under-mouse-cursor
