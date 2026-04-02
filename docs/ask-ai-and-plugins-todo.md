# Ask AI & Plugin System — Remaining TODO

## Current Status

**已完成：**
- `ChatWindow.swift` — 通用聊天窗口 UI（气泡布局、Markdown 渲染、多轮对话输入框、Copy 按钮）
- `ChatWindow.init(image:)` — 内置 Ask AI 模式，直接调用现有 AIService 进行流式对话
- `PluginManager.swift` — 插件管理器（加载 `~/.snipshot/plugins/` 下的插件、执行脚本、传递环境变量、支持 chat/once 两种模式）
- `PluginMode.swift` — Overlay 上的插件输入 UI（输入框 + 提交按钮，quick_prompt 插件直接执行）
- `OverlayWindow.swift` — 新增 `askAI` 和 `runPlugin` action，新增 `pluginInput` interaction mode，快捷键 Q 触发 Ask AI
- `OverlayPanels.swift` — 工具栏新增 Ask AI 按钮（sparkles 图标）
- `AppDelegate.swift` — 处理 `askAI` action（打开 ChatWindow）、新增 `chatWindow` 属性和 `showChatWindow` 方法
- `build.sh` — 已添加 `ChatWindow.swift`

**编译状态：** 已通过（Ask AI 功能可用）

## TODO

### 1. 完成 build.sh 集成
- [ ] 把 `PluginManager.swift` 和 `PluginMode.swift` 加到 `build.sh` 的源文件列表

### 2. AppDelegate 插件初始化
- [ ] 在 `applicationDidFinishLaunching` 中调用 `PluginManager.shared.loadPlugins()`
- [ ] 处理 `runPlugin` action：调用 `PluginManager.shared.executePlugin(plugin:image:inputText:)`

### 3. Overlay 工具栏插件入口
- [ ] 在工具栏上添加一个 "Plugins" 按钮（puzzle.piece 图标），仅在有已安装插件时显示
- [ ] 点击后弹出 NSMenu，列出所有已加载的插件（名称 + 图标）
- [ ] 点击某个插件后调用 `enterPluginMode(plugin)` 进入插件输入模式
- [ ] 需要重新计算工具栏总宽度（pluginCount > 0 时才加这个按钮的宽度）

### 4. Settings 插件管理界面
- [ ] 在 SettingsWindow 的 AI tab 或新建一个 Plugins tab
- [ ] 显示已安装插件数量和列表
- [ ] "Open Plugins Folder" 按钮（调用 `PluginManager.shared.openPluginsFolder()`）
- [ ] "Reload Plugins" 按钮（调用 `PluginManager.shared.loadPlugins()`）
- [ ] 可选：显示每个插件的 manifest 信息（名称、描述、模式）

### 5. ChatWindow 完善
- [ ] 确认 `imagePath` 和 `chatHistory` 属性是 public 的（PluginManager 需要访问）
- [ ] 确认 `addScreenshotThumbnail`、`addUserMessage`、`addAssistantMessage`、`showLoading` 方法可被 PluginManager 调用
- [ ] 确认 `onSendFollowUp` 回调在 chat 模式下正常工作
- [ ] 测试多轮对话的 chatHistory 序列化是否正确

### 6. 测试
- [ ] 测试 Ask AI 功能：截图 → Q → 输入问题 → 收到流式回复 → 追问
- [ ] 测试插件加载：在 `~/.snipshot/plugins/` 下放一个测试插件，确认能被加载
- [ ] 测试插件执行：once 模式和 chat 模式分别测试
- [ ] 测试 quick_prompt 插件：点击后直接执行，不弹输入框
- [ ] 测试无插件时工具栏不显示 Plugins 按钮

## 插件目录结构参考

```
~/.snipshot/plugins/
└── my-plugin/
    ├── manifest.json    # 必须，声明插件元数据
    ├── config.json      # 可选，用户可编辑配置（注入为 SNIPSHOT_* 环境变量）
    └── run.py           # 可执行脚本（支持 .py / .sh / .js）
```

### manifest.json 示例

```json
{
  "id": "com.example.my-plugin",
  "name": "My Plugin",
  "icon": "wand.and.stars",
  "description": "A custom plugin",
  "mode": "chat",
  "executable": "run.py",
  "inputs": [
    {
      "id": "prompt",
      "type": "text",
      "placeholder": "Enter your prompt..."
    }
  ]
}
```

### 脚本可用的环境变量

| 变量 | 说明 |
|---|---|
| `SNIPSHOT_IMAGE_PATH` | 截图临时文件路径（PNG） |
| `SNIPSHOT_INPUT_TEXT` | 用户输入的文本 |
| `SNIPSHOT_CHAT_HISTORY` | JSON 格式的聊天历史（OpenAI message 格式） |
| `SNIPSHOT_AI_API_ENDPOINT` | Snipshot 设置中的 AI API endpoint |
| `SNIPSHOT_AI_API_KEY` | Snipshot 设置中的 AI API key |
| `SNIPSHOT_AI_MODEL` | Snipshot 设置中的 AI model |
| `SNIPSHOT_<KEY>` | config.json 中的自定义配置 |
