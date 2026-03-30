import Foundation
import Cocoa

// MARK: - AI Settings (shared across all AI features)

struct AISettings {
    // Use same UserDefaults keys for backward compatibility
    static let apiEndpointKey = "llmApiEndpoint"
    static let apiKeyKey = "llmApiKey"
    static let modelKey = "llmModel"

    static let defaultEndpoint = "https://generativelanguage.googleapis.com/v1beta/openai/"
    static let defaultModel = "gemini-3-flash-preview"

    static var apiEndpoint: String {
        get { UserDefaults.standard.string(forKey: apiEndpointKey) ?? defaultEndpoint }
        set { UserDefaults.standard.set(newValue, forKey: apiEndpointKey) }
    }

    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyKey) }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    static var isConfigured: Bool {
        !apiKey.isEmpty
    }

    /// Migrate old translate-specific keys to new AI keys (one-time migration).
    static func migrateIfNeeded() {
        let ud = UserDefaults.standard
        if ud.string(forKey: apiKeyKey) == nil,
           let oldKey = ud.string(forKey: "translateApiKey"), !oldKey.isEmpty {
            ud.set(oldKey, forKey: apiKeyKey)
            ud.removeObject(forKey: "translateApiKey")
        }
        if ud.string(forKey: apiEndpointKey) == nil,
           let oldEndpoint = ud.string(forKey: "translateApiEndpoint") {
            ud.set(oldEndpoint, forKey: apiEndpointKey)
            ud.removeObject(forKey: "translateApiEndpoint")
        }
        if ud.string(forKey: modelKey) == nil,
           let oldModel = ud.string(forKey: "translateModel") {
            ud.set(oldModel, forKey: modelKey)
            ud.removeObject(forKey: "translateModel")
        }
    }
}

// MARK: - AI Errors

enum AIError: LocalizedError {
    case notConfigured
    case invalidEndpoint
    case noData
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "API key is not configured. Please set it in Settings."
        case .invalidEndpoint:
            return "Invalid API endpoint URL."
        case .noData:
            return "No response received from the API."
        case .apiError(let msg):
            return msg
        }
    }
}

// MARK: - AI Message

struct AIMessage {
    enum Role: String {
        case system
        case user
        case assistant
    }

    let role: Role
    let content: Any  // String or [[String: Any]] for multimodal

    /// Create a text-only message.
    static func text(role: Role, content: String) -> AIMessage {
        AIMessage(role: role, content: content)
    }

    /// Create a multimodal message with text and an image data URL.
    static func multimodal(role: Role, text: String, imageDataURL: String) -> AIMessage {
        let content: [[String: Any]] = [
            [
                "type": "image_url",
                "image_url": ["url": imageDataURL]
            ],
            [
                "type": "text",
                "text": text
            ]
        ]
        return AIMessage(role: role, content: content)
    }

    func toDict() -> [String: Any] {
        return ["role": role.rawValue, "content": content]
    }
}

// MARK: - AI Service (generic streaming AI client)

class AIService: NSObject, URLSessionDataDelegate {

    static let shared = AIService()

    private override init() {
        super.init()
    }

    // MARK: - Image Preparation

    /// Maximum dimension (width or height) for images sent to the API after Retina scaling.
    private let maxImageDimension: CGFloat = 2048

    /// JPEG compression quality for images sent to the API.
    private let imageQuality: CGFloat = 0.7

    /// Resize and compress an NSImage to a base64 JPEG data URL string.
    /// Automatically accounts for Retina display scaling.
    func prepareImageDataURL(from image: NSImage) -> String? {
        let originalSize = image.size
        guard originalSize.width > 0 && originalSize.height > 0 else { return nil }

        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0

        var targetSize = NSSize(
            width: originalSize.width / scaleFactor,
            height: originalSize.height / scaleFactor
        )

        let maxDim = max(targetSize.width, targetSize.height)
        if maxDim > maxImageDimension {
            let scale = maxImageDimension / maxDim
            targetSize = NSSize(width: targetSize.width * scale, height: targetSize.height * scale)
        }

        targetSize.width = max(1, round(targetSize.width))
        targetSize.height = max(1, round(targetSize.height))

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        image.draw(in: NSRect(origin: .zero, size: targetSize),
                   from: NSRect(origin: .zero, size: originalSize),
                   operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: imageQuality]) else {
            return nil
        }

        let base64 = jpegData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(base64)"

        logMessage("AI: image prepared, \(Int(originalSize.width))x\(Int(originalSize.height)) → \(Int(targetSize.width))x\(Int(targetSize.height)), scaleFactor=\(scaleFactor), \(jpegData.count / 1024)KB")
        return dataURL
    }

    // MARK: - Streaming Chat Completion

    // Streaming state
    private var streamBuffer = ""
    private var streamingContent = ""
    private var onChunk: ((String) -> Void)?
    private var onComplete: ((Result<String, Error>) -> Void)?
    private var currentSession: URLSession?
    private var currentHTTPStatusCode: Int?
    private var chunkCount = 0
    private var firstContentReceived = false
    private var logPrefix = "AI"

    /// Send a streaming chat completion request.
    ///
    /// - Parameters:
    ///   - messages: Array of AIMessage (system, user, assistant).
    ///   - temperature: Sampling temperature (default 0.3).
    ///   - logPrefix: Prefix for log messages (e.g. "Translate", "AskAI").
    ///   - onChunk: Called on main thread with accumulated content so far.
    ///   - completion: Called on main thread with final result or error.
    func streamChat(
        messages: [AIMessage],
        temperature: Double = 0.3,
        logPrefix: String = "AI",
        onChunk: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard AISettings.isConfigured else {
            DispatchQueue.main.async { completion(.failure(AIError.notConfigured)) }
            return
        }

        let endpoint = AISettings.apiEndpoint.hasSuffix("/")
            ? AISettings.apiEndpoint
            : AISettings.apiEndpoint + "/"
        let urlString = endpoint + "chat/completions"

        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(.failure(AIError.invalidEndpoint)) }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(AISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": AISettings.model,
            "messages": messages.map { $0.toDict() },
            "temperature": temperature,
            "stream": true,
            "reasoning_effort": "none"
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        }

        let bodySize = request.httpBody?.count ?? 0
        logMessage("\(logPrefix): streaming request to \(urlString), model=\(AISettings.model), body=\(bodySize / 1024)KB")

        // Reset streaming state
        streamBuffer = ""
        streamingContent = ""
        chunkCount = 0
        firstContentReceived = false
        currentHTTPStatusCode = nil
        self.logPrefix = logPrefix
        self.onChunk = onChunk
        self.onComplete = completion

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        currentSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = currentSession!.dataTask(with: request)
        task.resume()
    }

    /// Test the AI API connection. Returns nil on success, or an error message on failure.
    func testConnection(completion: @escaping (String?) -> Void) {
        let endpoint = AISettings.apiEndpoint.hasSuffix("/")
            ? AISettings.apiEndpoint
            : AISettings.apiEndpoint + "/"
        let urlString = endpoint + "chat/completions"

        guard let url = URL(string: urlString) else {
            completion("Invalid endpoint URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(AISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": AISettings.model,
            "messages": [
                ["role": "user", "content": "Hi"]
            ],
            "max_tokens": 5
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion("Failed to build request: \(error.localizedDescription)")
            return
        }

        logMessage("AI: testing connection to \(urlString), model=\(AISettings.model)")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion("Connection error: \(error.localizedDescription)")
                    return
                }

                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

                guard let data = data else {
                    completion("No response (HTTP \(httpStatus))")
                    return
                }

                if httpStatus != 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorObj = json["error"] as? [String: Any],
                       let message = errorObj["message"] as? String {
                        completion("HTTP \(httpStatus): \(message)")
                    } else if let bodyStr = String(data: data, encoding: .utf8)?.prefix(200) {
                        completion("HTTP \(httpStatus): \(bodyStr)")
                    } else {
                        completion("HTTP \(httpStatus)")
                    }
                    return
                }

                logMessage("AI: test connection successful")
                completion(nil)
            }
        }.resume()
    }

    /// Cancel any in-flight streaming request.
    func cancelCurrentRequest() {
        logMessage("\(logPrefix): cancelling current request")
        cleanupStream()
    }

    // MARK: - URLSessionDataDelegate (streaming)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse {
            currentHTTPStatusCode = httpResponse.statusCode
            logMessage("\(logPrefix): HTTP status \(httpResponse.statusCode)")
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        chunkCount += 1
        if chunkCount <= 5 || chunkCount % 20 == 0 {
            logMessage("\(logPrefix): didReceive chunk #\(chunkCount), \(data.count) bytes, buffer=\(streamBuffer.count)")
        }

        // Check for non-200 response — the body is likely a JSON error
        if let status = currentHTTPStatusCode, status != 200 {
            streamBuffer += text
            if let jsonData = streamBuffer.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let errorObj = json["error"] as? [String: Any],
               let message = errorObj["message"] as? String {
                let errorMsg = "HTTP \(status): \(message)"
                logMessage("\(logPrefix): API error: \(errorMsg)")
                DispatchQueue.main.async { [weak self] in
                    self?.onComplete?(.failure(AIError.apiError(errorMsg)))
                    self?.cleanupStream()
                }
            }
            return
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        streamBuffer += normalized

        while let lineEnd = streamBuffer.range(of: "\n") {
            let line = String(streamBuffer[streamBuffer.startIndex..<lineEnd.lowerBound])
            streamBuffer = String(streamBuffer[lineEnd.upperBound...])

            guard !line.isEmpty else { continue }

            if line.hasPrefix("data: ") {
                let jsonStr = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)

                if jsonStr == "[DONE]" {
                    logMessage("\(logPrefix): stream complete, \(streamingContent.count) chars, \(chunkCount) chunks")
                    let finalContent = streamingContent
                    DispatchQueue.main.async { [weak self] in
                        self?.onComplete?(.success(finalContent))
                        self?.cleanupStream()
                    }
                    return
                }

                if let jsonData = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

                    if let errorObj = json["error"] as? [String: Any],
                       let message = errorObj["message"] as? String {
                        let statusStr = currentHTTPStatusCode.map { "HTTP \($0): " } ?? ""
                        DispatchQueue.main.async { [weak self] in
                            self?.onComplete?(.failure(AIError.apiError("\(statusStr)\(message)")))
                            self?.cleanupStream()
                        }
                        return
                    }

                    if let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let delta = first["delta"] as? [String: Any],
                       let content = delta["content"] as? String,
                       !content.isEmpty {
                        streamingContent += content
                        if !firstContentReceived {
                            firstContentReceived = true
                            logMessage("\(logPrefix): first content token received: \"\(content.prefix(20))\"")
                        }
                        let accumulated = streamingContent
                        DispatchQueue.main.async { [weak self] in
                            self?.onChunk?(accumulated)
                        }
                    }
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let statusStr = currentHTTPStatusCode.map { " (HTTP \($0))" } ?? ""

        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            logMessage("\(logPrefix): stream error\(statusStr): \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.onComplete?(.failure(AIError.apiError("\(error.localizedDescription)\(statusStr)")))
                self?.cleanupStream()
            }
        } else if streamingContent.isEmpty {
            logMessage("\(logPrefix): stream ended with no content\(statusStr)")
            DispatchQueue.main.async { [weak self] in
                let msg = self?.currentHTTPStatusCode != nil && self?.currentHTTPStatusCode != 200
                    ? "HTTP \(self!.currentHTTPStatusCode!): No response received"
                    : "No response received from the API"
                self?.onComplete?(.failure(AIError.apiError(msg)))
                self?.cleanupStream()
            }
        } else {
            let finalContent = streamingContent
            logMessage("\(logPrefix): stream ended, \(finalContent.count) chars")
            DispatchQueue.main.async { [weak self] in
                self?.onComplete?(.success(finalContent))
                self?.cleanupStream()
            }
        }
    }

    private func cleanupStream() {
        onChunk = nil
        onComplete = nil
        currentSession?.invalidateAndCancel()
        currentSession = nil
        currentHTTPStatusCode = nil
    }
}
