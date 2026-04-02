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

// MARK: - Plugin Execution Mode
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

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            logMessage("No plugins found.")
            return
        }

        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
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

        // Create and show chat window
        let chatWindow = ChatWindow(title: plugin.manifest.name)
        chatWindow.imagePath = imgPath

        // Show screenshot thumbnail
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

        // Build environment: inject plugin config as SNIPSHOT_* env vars
        var env = ProcessInfo.processInfo.environment
        for (key, value) in plugin.config {
            env["SNIPSHOT_\(key.uppercased())"] = value
        }
        env["SNIPSHOT_IMAGE_PATH"] = imgPath.path
        env["SNIPSHOT_INPUT_TEXT"] = inputText
        env["SNIPSHOT_CHAT_HISTORY"] = "[]"

        // Also inject Snipshot's own AI settings so plugins can use them
        env["SNIPSHOT_AI_API_ENDPOINT"] = AISettings.apiEndpoint
        env["SNIPSHOT_AI_API_KEY"] = AISettings.apiKey
        env["SNIPSHOT_AI_MODEL"] = AISettings.model

        let pluginName = plugin.manifest.name

        DispatchQueue.global(qos: .userInitiated).async { [weak chatWindow] in
            logMessage("Plugin '\(pluginName)' starting script execution...")
            let result = self.runScript(plugin: plugin, environment: env)
            logMessage("Plugin '\(pluginName)' completed. Output length: \(result.count)")

            DispatchQueue.main.async {
                guard let cw = chatWindow else { return }
                cw.addAssistantMessage(result)

                // Build initial chat history for follow-ups
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

    private func executeFollowUp(plugin: Plugin, chatWindow: ChatWindow, inputText: String) {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in plugin.config {
            env["SNIPSHOT_\(key.uppercased())"] = value
        }
        env["SNIPSHOT_IMAGE_PATH"] = chatWindow.imagePath?.path ?? ""
        env["SNIPSHOT_INPUT_TEXT"] = inputText

        // Also inject Snipshot's own AI settings
        env["SNIPSHOT_AI_API_ENDPOINT"] = AISettings.apiEndpoint
        env["SNIPSHOT_AI_API_KEY"] = AISettings.apiKey
        env["SNIPSHOT_AI_MODEL"] = AISettings.model

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
