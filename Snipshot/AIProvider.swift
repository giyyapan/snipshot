import Foundation
import Security

enum AIProviderID: String, CaseIterable, Codable {
    case openAI
    case anthropic
    case openRouter
    case custom

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .openRouter: return "OpenRouter"
        case .custom: return "Custom"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-5.6-luna"
        case .anthropic: return "claude-haiku-4-5"
        case .openRouter: return "openai/gpt-5.6-luna"
        case .custom: return ""
        }
    }

    var helpURL: URL? {
        switch self {
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .openRouter: return URL(string: "https://openrouter.ai/settings/keys")
        case .custom: return nil
        }
    }
}

enum AICustomAuthMode: String, CaseIterable, Codable {
    case bearer
    case apiKeyHeader
    case none

    var displayName: String {
        switch self {
        case .bearer: return "Bearer token"
        case .apiKeyHeader: return "API key header"
        case .none: return "No authentication"
        }
    }
}

enum AICustomTokenParameter: String, CaseIterable, Codable {
    case maxTokens
    case maxCompletionTokens

    var displayName: String {
        switch self {
        case .maxTokens: return "max_tokens"
        case .maxCompletionTokens: return "max_completion_tokens"
        }
    }
}

struct AIProviderConfiguration: Codable, Equatable {
    var provider: AIProviderID
    var baseURL: String
    var model: String
    var customAuthMode: AICustomAuthMode = .bearer
    var customAPIKeyHeader: String = "X-API-Key"
    var customTokenParameter: AICustomTokenParameter = .maxTokens
    var customAllowsInsecureHTTP: Bool = false

    static var defaultConfiguration: AIProviderConfiguration {
        AIProviderConfiguration(
            provider: .openAI,
            baseURL: AIProviderID.openAI.defaultBaseURL,
            model: AIProviderID.openAI.defaultModel
        )
    }

    var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func validate(apiKey: String) throws {
        guard !trimmedBaseURL.isEmpty, let url = URL(string: trimmedBaseURL), url.host != nil else {
            throw AIProviderError.invalidConfiguration("Enter a valid base URL.")
        }
        if url.scheme?.lowercased() != "https" {
            let isLocalhost = url.host == "localhost" || url.host == "127.0.0.1" || url.host == "::1"
            guard provider == .custom && isLocalhost && customAllowsInsecureHTTP else {
                throw AIProviderError.invalidConfiguration("Use HTTPS, or explicitly allow HTTP for a localhost Custom endpoint.")
            }
        }
        guard !trimmedModel.isEmpty else {
            throw AIProviderError.invalidConfiguration("Choose or enter a model.")
        }
        let keyRequired = provider != .custom || customAuthMode != .none
        if keyRequired && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIProviderError.invalidConfiguration("Enter an API key.")
        }
        if provider == .custom && customAuthMode == .apiKeyHeader && customAPIKeyHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIProviderError.invalidConfiguration("Enter the Custom API key header name.")
        }
    }
}

struct AIModelDescriptor: Codable, Equatable {
    let id: String
    let displayName: String
    let inputModalities: Set<String>
    let supportedParameters: Set<String>
    let contextLength: Int?

    init(id: String, displayName: String? = nil, inputModalities: Set<String> = [], supportedParameters: Set<String> = [], contextLength: Int? = nil) {
        self.id = id
        self.displayName = displayName ?? id
        self.inputModalities = inputModalities
        self.supportedParameters = supportedParameters
        self.contextLength = contextLength
    }

    var supportsImages: Bool? {
        inputModalities.isEmpty ? nil : inputModalities.contains("image")
    }
}

enum AIMessageRole: String {
    case system
    case user
    case assistant
}

enum AIContentPart: Equatable {
    case text(String)
    case imageDataURL(String)
}

struct AIConversationMessage: Equatable {
    let role: AIMessageRole
    let parts: [AIContentPart]

    static func text(role: AIMessageRole, content: String) -> AIConversationMessage {
        AIConversationMessage(role: role, parts: [.text(content)])
    }

    static func multimodal(role: AIMessageRole, text: String, imageDataURL: String) -> AIConversationMessage {
        AIConversationMessage(role: role, parts: [.imageDataURL(imageDataURL), .text(text)])
    }
}

struct AIProviderRequest {
    let messages: [AIConversationMessage]
    let outputTokenLimit: Int?
    let stream: Bool

    init(messages: [AIConversationMessage], outputTokenLimit: Int? = nil, stream: Bool = true) {
        self.messages = messages
        self.outputTokenLimit = outputTokenLimit
        self.stream = stream
    }
}

enum AIProviderError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case http(status: Int, message: String, requestID: String?, retryAfter: String?)
    case transport(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .invalidResponse(let message), .transport(let message):
            return message
        case .cancelled:
            return "The request was cancelled."
        case .http(let status, let message, let requestID, let retryAfter):
            var details = "HTTP \(status): \(message)"
            if let retryAfter, !retryAfter.isEmpty { details += " Retry after \(retryAfter)." }
            if let requestID, !requestID.isEmpty { details += " Request ID: \(requestID)" }
            return details
        }
    }
}

enum AIEndpoint {
    static func url(baseURL: String, path: String) throws -> URL {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { throw AIProviderError.invalidConfiguration("Enter a base URL.") }
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base.hasSuffix("/\(cleanPath)") || base == cleanPath {
            guard let url = URL(string: base) else { throw AIProviderError.invalidConfiguration("Enter a valid base URL.") }
            return url
        }
        guard let url = URL(string: "\(base)/\(cleanPath)") else {
            throw AIProviderError.invalidConfiguration("Enter a valid base URL.")
        }
        return url
    }
}

struct AIBuiltRequest {
    let urlRequest: URLRequest
    let streamProtocol: AIStreamProtocol
    let responseProtocol: AIResponseProtocol
}

enum AIStreamProtocol {
    case openAIResponses
    case openAIChat
    case anthropicMessages
}

enum AIResponseProtocol {
    case openAIResponses
    case openAIChat
    case anthropicMessages
}

enum AIRequestBuilder {
    static func build(configuration: AIProviderConfiguration, apiKey: String, request: AIProviderRequest) throws -> AIBuiltRequest {
        try configuration.validate(apiKey: apiKey)
        switch configuration.provider {
        case .openAI:
            return try buildOpenAIResponses(configuration: configuration, apiKey: apiKey, request: request)
        case .anthropic:
            return try buildAnthropic(configuration: configuration, apiKey: apiKey, request: request)
        case .openRouter, .custom:
            return try buildChatCompletions(configuration: configuration, apiKey: apiKey, request: request)
        }
    }

    static func buildModelList(configuration: AIProviderConfiguration, apiKey: String) throws -> URLRequest {
        let placeholderModel = configuration.trimmedModel.isEmpty ? "model-list-placeholder" : configuration.trimmedModel
        var validated = configuration
        validated.model = placeholderModel
        try validated.validate(apiKey: apiKey)
        var request = URLRequest(url: try AIEndpoint.url(baseURL: configuration.trimmedBaseURL, path: "models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        applyHeaders(to: &request, configuration: configuration, apiKey: apiKey)
        return request
    }

    private static func buildOpenAIResponses(configuration: AIProviderConfiguration, apiKey: String, request: AIProviderRequest) throws -> AIBuiltRequest {
        var urlRequest = URLRequest(url: try AIEndpoint.url(baseURL: configuration.trimmedBaseURL, path: "responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        applyHeaders(to: &urlRequest, configuration: configuration, apiKey: apiKey)

        var body: [String: Any] = [
            "model": configuration.trimmedModel,
            "input": request.messages.map(openAIResponseMessage),
            "stream": request.stream
        ]
        if let limit = request.outputTokenLimit { body["max_output_tokens"] = limit }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return AIBuiltRequest(urlRequest: urlRequest, streamProtocol: .openAIResponses, responseProtocol: .openAIResponses)
    }

    private static func buildAnthropic(configuration: AIProviderConfiguration, apiKey: String, request: AIProviderRequest) throws -> AIBuiltRequest {
        var urlRequest = URLRequest(url: try AIEndpoint.url(baseURL: configuration.trimmedBaseURL, path: "messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        applyHeaders(to: &urlRequest, configuration: configuration, apiKey: apiKey)

        let system = request.messages.filter { $0.role == .system }.flatMap(\.parts).compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined(separator: "\n\n")
        let messages = request.messages.filter { $0.role != .system }.map(anthropicMessage)
        var body: [String: Any] = [
            "model": configuration.trimmedModel,
            "messages": messages,
            "max_tokens": request.outputTokenLimit ?? 4096,
            "stream": request.stream
        ]
        if !system.isEmpty { body["system"] = system }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return AIBuiltRequest(urlRequest: urlRequest, streamProtocol: .anthropicMessages, responseProtocol: .anthropicMessages)
    }

    private static func buildChatCompletions(configuration: AIProviderConfiguration, apiKey: String, request: AIProviderRequest) throws -> AIBuiltRequest {
        var urlRequest = URLRequest(url: try AIEndpoint.url(baseURL: configuration.trimmedBaseURL, path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        applyHeaders(to: &urlRequest, configuration: configuration, apiKey: apiKey)
        var body: [String: Any] = [
            "model": configuration.trimmedModel,
            "messages": request.messages.map(openAIChatMessage),
            "stream": request.stream
        ]
        if let limit = request.outputTokenLimit {
            let key = configuration.provider == .custom && configuration.customTokenParameter == .maxCompletionTokens
                ? "max_completion_tokens" : "max_tokens"
            body[key] = limit
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return AIBuiltRequest(urlRequest: urlRequest, streamProtocol: .openAIChat, responseProtocol: .openAIChat)
    }

    private static func applyHeaders(to request: inout URLRequest, configuration: AIProviderConfiguration, apiKey: String) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch configuration.provider {
        case .openAI, .openRouter:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .custom:
            switch configuration.customAuthMode {
            case .bearer:
                if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            case .apiKeyHeader:
                if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: configuration.customAPIKeyHeader) }
            case .none:
                break
            }
        }
    }

    private static func openAIChatMessage(_ message: AIConversationMessage) -> [String: Any] {
        let content: Any
        if message.parts.count == 1, case .text(let text) = message.parts[0] {
            content = text
        } else {
            content = message.parts.map { part -> [String: Any] in
                switch part {
                case .text(let text): return ["type": "text", "text": text]
                case .imageDataURL(let url): return ["type": "image_url", "image_url": ["url": url, "detail": "low"]]
                }
            }
        }
        return ["role": message.role.rawValue, "content": content]
    }

    private static func openAIResponseMessage(_ message: AIConversationMessage) -> [String: Any] {
        let content = message.parts.map { part -> [String: Any] in
            switch part {
            case .text(let text): return ["type": "input_text", "text": text]
            case .imageDataURL(let url): return ["type": "input_image", "image_url": url, "detail": "low"]
            }
        }
        return ["role": message.role.rawValue, "content": content]
    }

    private static func anthropicMessage(_ message: AIConversationMessage) -> [String: Any] {
        let content = message.parts.compactMap { part -> [String: Any]? in
            switch part {
            case .text(let text): return ["type": "text", "text": text]
            case .imageDataURL(let dataURL):
                guard let comma = dataURL.firstIndex(of: ",") else { return nil }
                let metadata = String(dataURL[..<comma])
                let data = String(dataURL[dataURL.index(after: comma)...])
                let mediaType = metadata
                    .replacingOccurrences(of: "data:", with: "")
                    .replacingOccurrences(of: ";base64", with: "")
                return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data]]
            }
        }
        return ["role": message.role.rawValue, "content": content]
    }
}

enum AIModelParser {
    static func parse(data: Data, provider: AIProviderID) throws -> [AIModelDescriptor] {
        try parsePage(data: data, provider: provider).models
    }

    static func parsePage(data: Data, provider: AIProviderID) throws -> (models: [AIModelDescriptor], hasMore: Bool, lastID: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else {
            throw AIProviderError.invalidResponse("The provider returned an invalid model list.")
        }
        let models = items.compactMap { item -> AIModelDescriptor? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            if provider == .openAI {
                let excluded = ["text-embedding", "dall-e", "tts-", "whisper-", "omni-moderation", "babbage-", "davinci-"]
                if excluded.contains(where: { id.lowercased().hasPrefix($0) }) { return nil }
            }
            let displayName = item["display_name"] as? String ?? item["name"] as? String ?? id
            let supported = Set(item["supported_parameters"] as? [String] ?? [])
            let architecture = item["architecture"] as? [String: Any]
            let modalities = Set(architecture?["input_modalities"] as? [String] ?? [])
            let contextLength = item["context_length"] as? Int
            return AIModelDescriptor(id: id, displayName: displayName, inputModalities: modalities, supportedParameters: supported, contextLength: contextLength)
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return (models, root["has_more"] as? Bool ?? false, root["last_id"] as? String)
    }
}

struct AIStreamParser {
    private(set) var buffer = ""
    let streamProtocol: AIStreamProtocol

    init(streamProtocol: AIStreamProtocol) {
        self.streamProtocol = streamProtocol
    }

    mutating func append(_ data: Data) throws -> (deltas: [String], completed: Bool) {
        guard let text = String(data: data, encoding: .utf8) else { return ([], false) }
        buffer += text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var deltas: [String] = []
        var completed = false
        while let boundary = buffer.range(of: "\n\n") {
            let event = String(buffer[..<boundary.lowerBound])
            buffer = String(buffer[boundary.upperBound...])
            let result = try parseEvent(event)
            if let delta = result.delta, !delta.isEmpty { deltas.append(delta) }
            completed = completed || result.completed
        }
        return (deltas, completed)
    }

    private func parseEvent(_ event: String) throws -> (delta: String?, completed: Bool) {
        let lines = event.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let dataLines = lines.filter { $0.hasPrefix("data:") }.map {
            String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        guard !dataLines.isEmpty else { return (nil, false) }
        let payload = dataLines.joined(separator: "\n")
        if payload == "[DONE]" { return (nil, true) }
        guard let jsonData = payload.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw AIProviderError.invalidResponse("The provider returned malformed streaming data.")
        }
        if let error = AIErrorParser.message(from: json) {
            throw AIProviderError.invalidResponse(error)
        }
        switch streamProtocol {
        case .openAIChat:
            let choices = json["choices"] as? [[String: Any]]
            let delta = choices?.first?["delta"] as? [String: Any]
            return (delta?["content"] as? String, false)
        case .openAIResponses:
            let type = json["type"] as? String
            if type == "response.output_text.delta" { return (json["delta"] as? String, false) }
            return (nil, type == "response.completed")
        case .anthropicMessages:
            let type = json["type"] as? String
            let delta = json["delta"] as? [String: Any]
            if type == "content_block_delta", delta?["type"] as? String == "text_delta" {
                return (delta?["text"] as? String, false)
            }
            return (nil, type == "message_stop")
        }
    }
}

enum AIResponseParser {
    static func parseText(data: Data, responseProtocol: AIResponseProtocol) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.invalidResponse("The provider returned invalid JSON.")
        }
        if let message = AIErrorParser.message(from: root) { throw AIProviderError.invalidResponse(message) }
        switch responseProtocol {
        case .openAIChat:
            let choices = root["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            guard let text = message?["content"] as? String, !text.isEmpty else {
                throw AIProviderError.invalidResponse("The provider returned no text.")
            }
            return text
        case .anthropicMessages:
            let content = root["content"] as? [[String: Any]]
            let text = content?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined() ?? ""
            guard !text.isEmpty else { throw AIProviderError.invalidResponse("Anthropic returned no text.") }
            return text
        case .openAIResponses:
            if let direct = root["output_text"] as? String, !direct.isEmpty { return direct }
            let output = root["output"] as? [[String: Any]]
            let text = output?.compactMap { $0["content"] as? [[String: Any]] }.flatMap { $0 }.compactMap {
                ($0["type"] as? String == "output_text") ? $0["text"] as? String : nil
            }.joined() ?? ""
            guard !text.isEmpty else { throw AIProviderError.invalidResponse("OpenAI returned no text.") }
            return text
        }
    }
}

enum AIErrorParser {
    static func message(from root: [String: Any]) -> String? {
        if let error = root["error"] as? [String: Any] {
            return error["message"] as? String ?? error["type"] as? String
        }
        if root["type"] as? String == "error", let message = root["message"] as? String { return message }
        return nil
    }

    static func httpError(status: Int, data: Data?, response: HTTPURLResponse) -> AIProviderError {
        var message = HTTPURLResponse.localizedString(forStatusCode: status)
        var bodyRequestID: String?
        if let data,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let parsed = self.message(from: root) { message = parsed }
            bodyRequestID = root["request_id"] as? String
        } else if let data, let text = String(data: data, encoding: .utf8), !text.isEmpty {
            message = String(text.prefix(300))
        }
        let requestID = response.value(forHTTPHeaderField: "request-id")
            ?? response.value(forHTTPHeaderField: "x-request-id")
            ?? bodyRequestID
        return .http(status: status, message: message, requestID: requestID, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
    }
}

protocol AICredentialStoring {
    func read(provider: AIProviderID) -> String
    func write(_ key: String, provider: AIProviderID) throws
    func delete(provider: AIProviderID)
}

final class KeychainAICredentialStore: AICredentialStoring {
    static let shared = KeychainAICredentialStore()
    static let service = "com.giyyapan.snipshot.ai"

    /// Snipshot is distributed as a non-sandboxed Developer ID app without
    /// a provisioning profile, so it intentionally uses the user's login
    /// keychain. The data-protection keychain requires a provisioned access
    /// group and otherwise fails with errSecMissingEntitlement (-34018).
    static func itemQuery(provider: AIProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
    }

    func read(provider: AIProviderID) -> String {
        var query = Self.itemQuery(provider: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    func write(_ key: String, provider: AIProviderID) throws {
        if key.isEmpty { delete(provider: provider); return }
        let accountQuery = Self.itemQuery(provider: provider)
        let data = Data(key.utf8)
        let status = SecItemUpdate(accountQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = accountQuery
            insert[kSecValueData as String] = data
            insert[kSecAttrLabel as String] = "Snipshot \(provider.displayName) API Key"
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw keychainError(action: "save", status: insertStatus)
            }
        } else if status != errSecSuccess {
            throw keychainError(action: "update", status: status)
        }
    }

    func delete(provider: AIProviderID) {
        SecItemDelete(Self.itemQuery(provider: provider) as CFDictionary)
    }

    private func keychainError(action: String, status: OSStatus) -> AIProviderError {
        let systemMessage = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
        return .invalidConfiguration("Could not \(action) the API key in macOS Keychain: \(systemMessage) (\(status)).")
    }
}

enum AIConfigurationStore {
    static let configurationKey = "aiProviderConfiguration"
    static let schemaVersionKey = "aiProviderConfigurationVersion"
    static let schemaVersion = 1
    static let migrationErrorKey = "aiProviderMigrationError"

    static func load(defaults: UserDefaults = .standard) -> AIProviderConfiguration {
        if let data = defaults.data(forKey: configurationKey),
           let config = try? JSONDecoder().decode(AIProviderConfiguration.self, from: data) {
            return config
        }
        return .defaultConfiguration
    }

    static func save(_ configuration: AIProviderConfiguration, defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(configuration), forKey: configurationKey)
        defaults.set(schemaVersion, forKey: schemaVersionKey)
    }

    static func migrateIfNeeded(defaults: UserDefaults = .standard, credentials: AICredentialStoring = KeychainAICredentialStore.shared) {
        guard defaults.integer(forKey: schemaVersionKey) < schemaVersion else { return }
        let endpoint = defaults.string(forKey: "llmApiEndpoint")
            ?? defaults.string(forKey: "translateApiEndpoint")
            ?? AIProviderConfiguration.defaultConfiguration.baseURL
        let model = defaults.string(forKey: "llmModel")
            ?? defaults.string(forKey: "translateModel")
            ?? AIProviderConfiguration.defaultConfiguration.model
        let oldKey = defaults.string(forKey: "llmApiKey")
            ?? defaults.string(forKey: "translateApiKey")
            ?? ""
        let lower = endpoint.lowercased()
        let provider: AIProviderID
        if lower.contains("api.openai.com") { provider = .openAI }
        else if lower.contains("api.anthropic.com") { provider = .anthropic }
        else if lower.contains("openrouter.ai") { provider = .openRouter }
        else { provider = .custom }
        let config = AIProviderConfiguration(provider: provider, baseURL: endpoint, model: model)
        do {
            if !oldKey.isEmpty {
                try credentials.write(oldKey, provider: provider)
                guard credentials.read(provider: provider) == oldKey else {
                    throw AIProviderError.invalidConfiguration("The migrated API key could not be verified in Keychain.")
                }
            }
            try save(config, defaults: defaults)
            ["llmApiKey", "llmApiEndpoint", "llmModel", "translateApiKey", "translateApiEndpoint", "translateModel"].forEach {
                defaults.removeObject(forKey: $0)
            }
            defaults.removeObject(forKey: migrationErrorKey)
        } catch {
            defaults.set(error.localizedDescription, forKey: migrationErrorKey)
        }
    }
}

struct AISettings {
    static var configuration: AIProviderConfiguration {
        get { AIConfigurationStore.load() }
        set { try? AIConfigurationStore.save(newValue) }
    }

    static var apiEndpoint: String {
        get { configuration.baseURL }
        set { var value = configuration; value.baseURL = newValue; configuration = value }
    }

    static var model: String {
        get { configuration.model }
        set { var value = configuration; value.model = newValue; configuration = value }
    }

    static var apiKey: String {
        get { KeychainAICredentialStore.shared.read(provider: configuration.provider) }
        set { try? KeychainAICredentialStore.shared.write(newValue, provider: configuration.provider) }
    }

    static func apiKey(for provider: AIProviderID) -> String {
        KeychainAICredentialStore.shared.read(provider: provider)
    }

    static var isConfigured: Bool {
        let config = configuration
        return !config.trimmedBaseURL.isEmpty && !config.trimmedModel.isEmpty
            && (config.provider == .custom && config.customAuthMode == .none || !apiKey.isEmpty)
    }

    static func save(configuration: AIProviderConfiguration, apiKey: String) throws {
        try configuration.validate(apiKey: apiKey)
        try KeychainAICredentialStore.shared.write(apiKey, provider: configuration.provider)
        try AIConfigurationStore.save(configuration)
    }

    static func migrateIfNeeded() {
        AIConfigurationStore.migrateIfNeeded()
    }
}
