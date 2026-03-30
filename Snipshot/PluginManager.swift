import Cocoa

// MARK: - Plugin Input Definition
struct PluginInput: Codable {
    let id: String
    let type: String           // "text", "select", etc.
    let placeholder: String?
    let defaultValue: String?

    enum CodingKeys: String, CodingKey {
        case id, type, placeholder
        case defaultValue = "default"
    }
}

// MARK: - Plugin Mode
enum PluginExecMode: String, Codable {
    case once  // Single response, no follow-up
    case chat  // Conversational, allows follow-up input
}

// MARK: - Plugin Manifest
struct PluginManifest: Codable {
    let id: String
    let name: String
    let icon: String           // SF Symbol name
    let description: String?
    let inputs: [PluginInput]?
    let executable: String     // relative path to script inside plugin dir
    let mode: PluginExecMode?  // "once" (default) or "chat"
    let quickPrompt: String?   // If set, plugin runs immediately with this prompt (no input UI)

    enum CodingKeys: String, CodingKey {
        case id, name, icon, description, inputs, executable, mode
        case quickPrompt = "quick_prompt"
    }

    var resolvedMode: PluginExecMode { mode ?? .once }
    /// True if this plugin should execute immediately on click (no input field)
    var isQuickAction: Bool { quickPrompt != nil }
}

// MARK: - Plugin
class Plugin {
    let manifest: PluginManifest
    let directory: URL
    var config: [String: String]  // user-editable config (loaded from config.json)

    var executableURL: URL { directory.appendingPathComponent(manifest.executable) }
    var configURL: URL { directory.appendingPathComponent("config.json") }

    init(manifest: PluginManifest, directory: URL) {
        self.manifest = manifest
        self.directory = directory
        self.config = [:]
        loadConfig()
    }

    func loadConfig() {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        config = dict
    }

    func saveConfig() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: configURL, options: .atomic)
    }
}

// MARK: - Plugin Manager (Singleton)
class PluginManager {
    static let shared = PluginManager()

    private(set) var plugins: [Plugin] = []

    /// Plugin directory: ~/.snipshot/plugins/
    var pluginsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".snipshot/plugins")
    }

    private init() {}

    // MARK: - Load Plugins

    func loadPlugins() {
        plugins.removeAll()
        let dir = pluginsDirectory

        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            logMessage("Created plugins directory: \(dir.path)")
        }

        installBundledPluginsIfNeeded()

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            logMessage("No plugins found.")
            return
        }

        for item in contents {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let manifestURL = item.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
                logMessage("Skipping invalid plugin at \(item.lastPathComponent)")
                continue
            }

            let plugin = Plugin(manifest: manifest, directory: item)
            plugins.append(plugin)
            logMessage("Loaded plugin: \(manifest.name) (\(manifest.id)) mode=\(manifest.resolvedMode.rawValue)")
        }

        logMessage("Loaded \(plugins.count) plugin(s).")
    }

    // MARK: - Bundled Plugin Installation

    private func installBundledPluginsIfNeeded() {
        let dir = pluginsDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let hasPlugins = contents.contains { name in
            var isDir: ObjCBool = false
            let path = dir.appendingPathComponent(name).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }

        if hasPlugins { return }

        logMessage("First run: installing bundled plugins...")

        // Migrate from old location if it exists
        let oldDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Snipshot/Plugins")
        if FileManager.default.fileExists(atPath: oldDir.path) {
            if let oldContents = try? FileManager.default.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil) {
                for item in oldContents {
                    let dest = dir.appendingPathComponent(item.lastPathComponent)
                    try? FileManager.default.copyItem(at: item, to: dest)
                    logMessage("Migrated plugin from old location: \(item.lastPathComponent)")
                }
                return
            }
        }

        installLLMPlugin(at: dir)
        installDescribePlugin(at: dir)
    }

    private func installLLMPlugin(at dir: URL) {
        let pluginDir = dir.appendingPathComponent("llm-prompt")
        try? FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let manifest = """
        {
          "id": "com.snipshot.llm-prompt",
          "name": "Ask LLM",
          "icon": "sparkles",
          "description": "Send screenshot to LLM with a prompt and get a response",
          "mode": "chat",
          "inputs": [
            {
              "id": "prompt",
              "type": "text",
              "placeholder": "Ask anything about this screenshot..."
            }
          ],
          "executable": "run.py"
        }
        """
        try? manifest.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let config = """
        {
          "api_url": "https://llm-router.butterfly-effect.dev/v1/chat/completions",
          "model": "gemini-3-flash-preview",
          "api_key": "dsad",
          "extra_headers": "{\\"x-request-resource-group\\": \\"5\\", \\"x-request-options\\": \\"{}\\", \\"x-request-stage-name\\": \\"6\\", \\"x-request-task-type\\": \\"next_agent_main\\"}"
        }
        """
        try? config.write(to: pluginDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let script = """
        #!/usr/bin/env python3
        \"\"\"
        Snipshot LLM Prompt Plugin (chat mode)
        Supports both initial and follow-up messages via SNIPSHOT_CHAT_HISTORY.
        \"\"\"
        import os, sys, json, base64, urllib.request, urllib.error

        def main():
            api_url = os.environ.get("SNIPSHOT_API_URL", "")
            model = os.environ.get("SNIPSHOT_MODEL", "gemini-3-flash-preview")
            api_key = os.environ.get("SNIPSHOT_API_KEY", "dsad")
            extra_headers_str = os.environ.get("SNIPSHOT_EXTRA_HEADERS", "{}")
            image_path = os.environ.get("SNIPSHOT_IMAGE_PATH", "")
            prompt = os.environ.get("SNIPSHOT_INPUT_TEXT", "Describe this image")
            chat_history_str = os.environ.get("SNIPSHOT_CHAT_HISTORY", "[]")

            try:
                extra_headers = json.loads(extra_headers_str)
            except json.JSONDecodeError:
                extra_headers = {}

            headers = {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {api_key}",
            }
            headers.update(extra_headers)

            try:
                chat_history = json.loads(chat_history_str)
            except json.JSONDecodeError:
                chat_history = []

            if not chat_history:
                # First message: include the image
                content = [{"type": "text", "text": prompt}]
                if image_path and os.path.exists(image_path):
                    with open(image_path, "rb") as f:
                        b64 = base64.b64encode(f.read()).decode("utf-8")
                    content.append({
                        "type": "image_url",
                        "image_url": {"url": f"data:image/png;base64,{b64}"}
                    })
                messages = [{"role": "user", "content": content}]
            else:
                messages = chat_history
                messages.append({"role": "user", "content": prompt})

            payload = {"model": model, "messages": messages, "max_tokens": 4096, "thinking": {"budget_tokens": 128}}
            data = json.dumps(payload).encode("utf-8")
            req = urllib.request.Request(api_url, data=data, headers=headers, method="POST")

            try:
                with urllib.request.urlopen(req, timeout=120) as response:
                    result = json.loads(response.read().decode("utf-8"))
                    choices = result.get("choices", [])
                    if choices:
                        print(choices[0].get("message", {}).get("content", ""))
                    else:
                        print("No response from LLM.")
            except urllib.error.HTTPError as e:
                body = e.read().decode("utf-8", errors="replace")
                print(f"HTTP Error {e.code}: {e.reason}\\n{body}")
                sys.exit(1)
            except urllib.error.URLError as e:
                print(f"Connection Error: {e.reason}")
                sys.exit(1)
            except Exception as e:
                print(f"Error: {str(e)}")
                sys.exit(1)

        if __name__ == "__main__":
            main()
        """
        try? script.write(to: pluginDir.appendingPathComponent("run.py"), atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: pluginDir.appendingPathComponent("run.py").path
        )

        logMessage("Installed bundled plugin: llm-prompt")
    }

    private func installDescribePlugin(at dir: URL) {
        let pluginDir = dir.appendingPathComponent("describe-screenshot")
        try? FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let manifest = """
        {
          "id": "com.snipshot.describe",
          "name": "Describe",
          "icon": "text.magnifyingglass",
          "description": "Instantly describe the screenshot content",
          "mode": "chat",
          "quick_prompt": "Describe what you see in this screenshot. Be concise and informative.",
          "executable": "run.py"
        }
        """
        try? manifest.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        // Reuse the same config as llm-prompt
        let config = """
        {
          "api_url": "https://llm-router.butterfly-effect.dev/v1/chat/completions",
          "model": "gemini-3-flash-preview",
          "api_key": "dsad",
          "extra_headers": "{\\"x-request-resource-group\\": \\"5\\", \\"x-request-options\\": \\"{}\\"}"
        }
        """
        try? config.write(to: pluginDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        // Symlink to the same run.py as llm-prompt (they share the same script)
        let srcScript = dir.appendingPathComponent("llm-prompt/run.py")
        let dstScript = pluginDir.appendingPathComponent("run.py")
        try? FileManager.default.createSymbolicLink(at: dstScript, withDestinationURL: srcScript)

        logMessage("Installed bundled plugin: describe-screenshot")
    }

    // MARK: - Execute Plugin (Initial)

    /// Run a plugin. Opens a chat window immediately with loading state.
    /// The overlay is already dismissed when this is called.
    func executePlugin(plugin: Plugin, image: NSImage, inputText: String) {
        // Save image to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let imgPath = tempDir.appendingPathComponent("snipshot_plugin_\(UUID().uuidString).png")

        if let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: imgPath)
            logMessage("Plugin image saved: \(imgPath.path) (\(pngData.count) bytes)")
        } else {
            logMessage("Plugin: failed to save image to temp file")
        }

        let isChatMode = plugin.manifest.resolvedMode == .chat

        // Create and show chat window immediately
        let chatWindow = PluginChatWindow(title: plugin.manifest.name, chatMode: isChatMode)
        chatWindow.plugin = plugin
        chatWindow.imagePath = imgPath

        // Show screenshot thumbnail at the top of the chat
        chatWindow.addScreenshotThumbnail(image)

        chatWindow.addUserMessage(inputText)
        chatWindow.showLoading()
        chatWindow.makeKeyAndOrderFront(nil)

        // Set up follow-up handler for chat mode
        if isChatMode {
            chatWindow.onSendFollowUp = { [weak self, weak chatWindow] followUpText in
                guard let self = self, let cw = chatWindow else { return }
                self.executeFollowUp(plugin: plugin, chatWindow: cw, inputText: followUpText)
            }
        }

        // Build environment
        var env = ProcessInfo.processInfo.environment
        for (key, value) in plugin.config {
            env["SNIPSHOT_\(key.uppercased())"] = value
        }
        env["SNIPSHOT_IMAGE_PATH"] = imgPath.path
        env["SNIPSHOT_INPUT_TEXT"] = inputText
        env["SNIPSHOT_CHAT_HISTORY"] = "[]"

        let pluginName = plugin.manifest.name

        DispatchQueue.global(qos: .userInitiated).async { [weak chatWindow] in
            logMessage("Plugin '\(pluginName)' starting script execution...")
            let result = self.runScript(plugin: plugin, environment: env)
            logMessage("Plugin '\(pluginName)' completed. Output length: \(result.count)")

            DispatchQueue.main.async {
                guard let cw = chatWindow else { return }
                cw.addAssistantMessage(result)

                // Build initial chat history for follow-ups
                // First user message includes the image reference
                if let imgData = try? Data(contentsOf: imgPath) {
                    let b64 = imgData.base64EncodedString()
                    cw.chatHistory.append([
                        "role": "user",
                        "content": [
                            ["type": "text", "text": inputText],
                            ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(b64)"]]
                        ] as [[String: Any]]
                    ])
                } else {
                    cw.chatHistory.append(["role": "user", "content": inputText])
                }
                cw.chatHistory.append(["role": "assistant", "content": result])

                // For "once" mode, clean up temp image
                if !isChatMode {
                    try? FileManager.default.removeItem(at: imgPath)
                }
            }
        }
    }

    // MARK: - Execute Follow-up (Chat Mode)

    private func executeFollowUp(plugin: Plugin, chatWindow: PluginChatWindow, inputText: String) {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in plugin.config {
            env["SNIPSHOT_\(key.uppercased())"] = value
        }
        env["SNIPSHOT_IMAGE_PATH"] = chatWindow.imagePath?.path ?? ""
        env["SNIPSHOT_INPUT_TEXT"] = inputText

        // Serialize current chat history
        if let historyData = try? JSONSerialization.data(withJSONObject: chatWindow.chatHistory),
           let historyStr = String(data: historyData, encoding: .utf8) {
            env["SNIPSHOT_CHAT_HISTORY"] = historyStr
        } else {
            env["SNIPSHOT_CHAT_HISTORY"] = "[]"
        }

        let pluginName = plugin.manifest.name

        DispatchQueue.global(qos: .userInitiated).async { [weak chatWindow] in
            logMessage("Plugin '\(pluginName)' follow-up execution...")
            let result = self.runScript(plugin: plugin, environment: env)
            logMessage("Plugin '\(pluginName)' follow-up completed. Output length: \(result.count)")

            DispatchQueue.main.async {
                guard let cw = chatWindow else { return }
                cw.addAssistantMessage(result)

                // Append to chat history
                cw.chatHistory.append(["role": "user", "content": inputText])
                cw.chatHistory.append(["role": "assistant", "content": result])
            }
        }
    }

    // MARK: - Script Runner

    func runScript(plugin: Plugin, environment: [String: String]) -> String {
        let process = Process()
        let pipe = Pipe()
        let errPipe = Pipe()

        let execURL = plugin.executableURL

        let ext = execURL.pathExtension.lowercased()
        switch ext {
        case "py":
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", execURL.path]
        case "sh":
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [execURL.path]
        case "js":
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", execURL.path]
        default:
            process.executableURL = execURL
        }

        process.currentDirectoryURL = plugin.directory
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return "Error launching plugin: \(error.localizedDescription)"
        }

        var outputData = Data()
        var errorData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.wait()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 && !errorOutput.isEmpty {
            return "Error (exit \(process.terminationStatus)):\n\(errorOutput)\n\(output)"
        }

        return output.isEmpty ? errorOutput : output
    }

    // MARK: - Open Plugin Folder

    func openPluginsFolder() {
        NSWorkspace.shared.open(pluginsDirectory)
    }
}
