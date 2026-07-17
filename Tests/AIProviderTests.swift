import Foundation
import Security

private enum TestFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let value): return value }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.message(message) }
}

private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    guard let data = request.httpBody,
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TestFailure.message("Missing JSON body")
    }
    return json
}

private final class MemoryCredentials: AICredentialStoring {
    var values: [AIProviderID: String] = [:]
    func read(provider: AIProviderID) -> String { values[provider] ?? "" }
    func write(_ key: String, provider: AIProviderID) throws { values[provider] = key }
    func delete(provider: AIProviderID) { values.removeValue(forKey: provider) }
}

private final class FailingCredentials: AICredentialStoring {
    func read(provider: AIProviderID) -> String { "" }
    func write(_ key: String, provider: AIProviderID) throws { throw TestFailure.message("Keychain unavailable") }
    func delete(provider: AIProviderID) {}
}

@main
struct AIProviderTests {
    static func main() throws {
        try testEndpointJoining()
        try testProviderDefaultsAndKeychainBackend()
        try testOpenAIResponsesRequest()
        try testAnthropicRequest()
        try testOpenRouterAndCustomRequests()
        try testStreamParsers()
        try testModelAndResponseParsers()
        try testMigration()
        print("AIProviderTests: 8 passed")
    }

    private static func testProviderDefaultsAndKeychainBackend() throws {
        try expect(AIProviderID.openAI.defaultModel == "gpt-5.6-luna", "OpenAI default is not the current lightweight generation")
        try expect(AIProviderID.anthropic.defaultModel == "claude-haiku-4-5", "Anthropic default is not the current lightweight model")
        try expect(AIProviderID.openRouter.defaultModel == "openai/gpt-5.6-luna", "OpenRouter default is not the current lightweight generation")
        let defaultConfiguration = AIProviderConfiguration.defaultConfiguration
        try expect(defaultConfiguration.provider == .openAI, "Fresh installs should start with a mainstream provider")
        try expect(defaultConfiguration.model == AIProviderID.openAI.defaultModel, "Fresh-install model and provider default diverged")

        let keychainQuery = KeychainAICredentialStore.itemQuery(provider: .openAI)
        try expect(keychainQuery[kSecAttrService as String] as? String == KeychainAICredentialStore.service, "Keychain service is unstable")
        try expect(keychainQuery[kSecAttrAccount as String] as? String == AIProviderID.openAI.rawValue, "Provider credentials are not isolated")
        try expect(keychainQuery[kSecUseDataProtectionKeychain as String] == nil, "Unprovisioned Developer ID builds cannot use the data-protection keychain")
    }

    private static func testEndpointJoining() throws {
        let joined = try AIEndpoint.url(baseURL: "https://api.openai.com/v1/", path: "/responses")
        let existing = try AIEndpoint.url(baseURL: "https://example.com/v1/chat/completions", path: "chat/completions")
        try expect(joined.absoluteString == "https://api.openai.com/v1/responses", "URL joining failed")
        try expect(existing.absoluteString == "https://example.com/v1/chat/completions", "Duplicate path was added")
    }

    private static func testOpenAIResponsesRequest() throws {
        let config = AIProviderConfiguration(provider: .openAI, baseURL: AIProviderID.openAI.defaultBaseURL, model: "o3")
        let built = try AIRequestBuilder.build(configuration: config, apiKey: "secret", request: AIProviderRequest(messages: [.text(role: .system, content: "Be concise"), .text(role: .user, content: "Hi")], outputTokenLimit: 32, stream: true))
        let body = try jsonBody(built.urlRequest)
        try expect(built.urlRequest.url?.path == "/v1/responses", "OpenAI should use Responses")
        try expect(built.urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer secret", "OpenAI auth missing")
        try expect(body["max_output_tokens"] as? Int == 32, "OpenAI max_output_tokens missing")
        try expect(body["max_tokens"] == nil && body["max_completion_tokens"] == nil, "Legacy token parameter leaked into Responses")
        try expect(body["reasoning_effort"] == nil && body["temperature"] == nil, "Unsupported optional parameter leaked")
    }

    private static func testAnthropicRequest() throws {
        let config = AIProviderConfiguration(provider: .anthropic, baseURL: AIProviderID.anthropic.defaultBaseURL, model: "claude-sonnet-4-5")
        let built = try AIRequestBuilder.build(configuration: config, apiKey: "anthropic-key", request: AIProviderRequest(messages: [.text(role: .system, content: "Translate"), .multimodal(role: .user, text: "Hello", imageDataURL: "data:image/jpeg;base64,AAAA")], outputTokenLimit: 64, stream: true))
        let body = try jsonBody(built.urlRequest)
        try expect(built.urlRequest.url?.path == "/v1/messages", "Anthropic endpoint incorrect")
        try expect(built.urlRequest.value(forHTTPHeaderField: "x-api-key") == "anthropic-key", "Anthropic key header missing")
        try expect(built.urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Anthropic version missing")
        try expect(body["system"] as? String == "Translate", "Anthropic system field missing")
        try expect(body["max_tokens"] as? Int == 64, "Anthropic required max_tokens missing")
        let messages = body["messages"] as? [[String: Any]]
        let content = messages?.first?["content"] as? [[String: Any]]
        try expect(content?.first?["type"] as? String == "image", "Anthropic image block missing")
    }

    private static func testOpenRouterAndCustomRequests() throws {
        let openRouter = AIProviderConfiguration(provider: .openRouter, baseURL: AIProviderID.openRouter.defaultBaseURL, model: "openai/gpt-5-mini")
        let routerBuilt = try AIRequestBuilder.build(configuration: openRouter, apiKey: "router", request: AIProviderRequest(messages: [.text(role: .user, content: "Hi")], outputTokenLimit: 10, stream: false))
        try expect(routerBuilt.urlRequest.url?.path == "/api/v1/chat/completions", "OpenRouter endpoint incorrect")
        let routerBody = try jsonBody(routerBuilt.urlRequest)
        try expect(routerBody["max_tokens"] as? Int == 10, "OpenRouter max_tokens missing")

        var custom = AIProviderConfiguration(provider: .custom, baseURL: "http://localhost:11434/v1", model: "local")
        custom.customAuthMode = .none
        custom.customTokenParameter = .maxCompletionTokens
        custom.customAllowsInsecureHTTP = true
        let customBuilt = try AIRequestBuilder.build(configuration: custom, apiKey: "", request: AIProviderRequest(messages: [.text(role: .user, content: "Hi")], outputTokenLimit: 12, stream: false))
        let body = try jsonBody(customBuilt.urlRequest)
        try expect(customBuilt.urlRequest.value(forHTTPHeaderField: "Authorization") == nil, "Custom no-auth request has Authorization")
        try expect(body["max_completion_tokens"] as? Int == 12 && body["max_tokens"] == nil, "Custom token parameter policy ignored")
    }

    private static func testStreamParsers() throws {
        var chat = AIStreamParser(streamProtocol: .openAIChat)
        let chatResult = try chat.append(Data(": keepalive\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\ndata: [DONE]\n\n".utf8))
        try expect(chatResult.deltas == ["Hi"] && chatResult.completed, "OpenAI Chat stream parse failed")

        var responses = AIStreamParser(streamProtocol: .openAIResponses)
        let responseResult = try responses.append(Data("event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"OK\"}\n\ndata: {\"type\":\"response.completed\"}\n\n".utf8))
        try expect(responseResult.deltas == ["OK"] && responseResult.completed, "OpenAI Responses stream parse failed")

        var anthropic = AIStreamParser(streamProtocol: .anthropicMessages)
        let anthropicResult = try anthropic.append(Data("event: ping\ndata: {\"type\":\"ping\"}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8))
        try expect(anthropicResult.deltas == ["Hello"] && anthropicResult.completed, "Anthropic stream parse failed")
    }

    private static func testModelAndResponseParsers() throws {
        let modelsJSON = Data("{\"data\":[{\"id\":\"model-b\",\"name\":\"Beta\",\"architecture\":{\"input_modalities\":[\"text\",\"image\"]},\"supported_parameters\":[\"max_tokens\"],\"context_length\":8192},{\"id\":\"model-a\",\"name\":\"Alpha\"}]}".utf8)
        let models = try AIModelParser.parse(data: modelsJSON, provider: .openRouter)
        try expect(models.map(\.id) == ["model-a", "model-b"], "Models were not normalized/sorted")
        try expect(models[1].supportsImages == true && models[1].supportedParameters.contains("max_tokens"), "OpenRouter capabilities missing")
        let pageJSON = Data("{\"data\":[{\"id\":\"claude-a\"}],\"has_more\":true,\"last_id\":\"cursor-1\"}".utf8)
        let page = try AIModelParser.parsePage(data: pageJSON, provider: .anthropic)
        try expect(page.hasMore && page.lastID == "cursor-1", "Anthropic pagination metadata missing")

        let openAI = Data("{\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"OK\"}]}]}".utf8)
        let openAIText = try AIResponseParser.parseText(data: openAI, responseProtocol: .openAIResponses)
        try expect(openAIText == "OK", "OpenAI response parse failed")
        let anthropic = Data("{\"content\":[{\"type\":\"text\",\"text\":\"OK\"}]}".utf8)
        let anthropicText = try AIResponseParser.parseText(data: anthropic, responseProtocol: .anthropicMessages)
        try expect(anthropicText == "OK", "Anthropic response parse failed")
    }

    private static func testMigration() throws {
        let suite = "AIProviderTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw TestFailure.message("Could not create test defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://openrouter.ai/api/v1", forKey: "llmApiEndpoint")
        defaults.set("openai/gpt-5-mini", forKey: "llmModel")
        defaults.set("old-secret", forKey: "llmApiKey")
        let credentials = MemoryCredentials()
        AIConfigurationStore.migrateIfNeeded(defaults: defaults, credentials: credentials)
        let config = AIConfigurationStore.load(defaults: defaults)
        try expect(config.provider == .openRouter && config.model == "openai/gpt-5-mini", "Provider migration failed")
        try expect(credentials.read(provider: .openRouter) == "old-secret", "Credential migration failed")
        try expect(defaults.string(forKey: "llmApiKey") == nil, "Plaintext key was not removed")
        AIConfigurationStore.migrateIfNeeded(defaults: defaults, credentials: credentials)
        try expect(AIConfigurationStore.load(defaults: defaults) == config, "Migration is not idempotent")

        let failureSuite = "AIProviderTests.failure.\(UUID().uuidString)"
        guard let failureDefaults = UserDefaults(suiteName: failureSuite) else { throw TestFailure.message("Could not create failure defaults") }
        defer { failureDefaults.removePersistentDomain(forName: failureSuite) }
        failureDefaults.set("https://api.openai.com/v1", forKey: "llmApiEndpoint")
        failureDefaults.set("gpt-5-mini", forKey: "llmModel")
        failureDefaults.set("must-survive", forKey: "llmApiKey")
        AIConfigurationStore.migrateIfNeeded(defaults: failureDefaults, credentials: FailingCredentials())
        try expect(failureDefaults.string(forKey: "llmApiKey") == "must-survive", "Failed migration deleted plaintext recovery data")
        try expect(failureDefaults.string(forKey: AIConfigurationStore.migrationErrorKey) != nil, "Failed migration did not record a recoverable error")
    }
}
