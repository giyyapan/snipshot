import Foundation
import AppKit

// MARK: - Notion OAuth Settings

struct NotionSettings {
    // OAuth credentials (set by developer, baked into the app)
    static let clientId     = NotionSecrets.clientId
    static let clientSecret = NotionSecrets.clientSecret
    static let redirectURI  = "https://oauth.snipshot.click/notion/callback"

    // Stored per-user after OAuth
    static let accessTokenKey  = "notionOAuthAccessToken"
    static let workspaceIdKey  = "notionOAuthWorkspaceId"
    static let workspaceNameKey = "notionOAuthWorkspaceName"
    static let botIdKey        = "notionOAuthBotId"
    static let ownerUserIdKey  = "notionOAuthOwnerUserId"

    static var accessToken: String {
        get { UserDefaults.standard.string(forKey: accessTokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: accessTokenKey) }
    }
    static var workspaceName: String {
        get { UserDefaults.standard.string(forKey: workspaceNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: workspaceNameKey) }
    }
    static var ownerUserId: String {
        get { UserDefaults.standard.string(forKey: ownerUserIdKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: ownerUserIdKey) }
    }

    // Database ID for the bug tracker (fixed for the team)
    static let databaseId = "15d7ff657cfa83d88e0f815e989e43a5"

    static var isAuthorized: Bool { !accessToken.isEmpty }

    static func clearToken() {
        UserDefaults.standard.removeObject(forKey: accessTokenKey)
        UserDefaults.standard.removeObject(forKey: workspaceIdKey)
        UserDefaults.standard.removeObject(forKey: workspaceNameKey)
        UserDefaults.standard.removeObject(forKey: botIdKey)
        UserDefaults.standard.removeObject(forKey: ownerUserIdKey)
    }
}

// MARK: - Notion Bug Input

struct NotionBugInput {
    var title: String
    var notes: String
    var priority: String   // "P0" | "P1" | "P2" | "长期优化"
    var feedbackType: String  // "后端问题" | "设计系统" | "前端页面" | "ROI"
    var image: NSImage
}

// MARK: - Notion OAuth Service

class NotionService {
    static let shared = NotionService()
    private init() {}

    private let baseURL = "https://api.notion.com/v1"
    private let notionVersion = "2026-03-11"

    // MARK: - OAuth Flow

    private var localServer: LocalOAuthServer?
    private var oauthCompletion: ((Result<Void, Error>) -> Void)?

    /// Opens Notion OAuth in the browser and starts local callback server.
    func startOAuth(completion: @escaping (Result<Void, Error>) -> Void) {
        self.oauthCompletion = completion

        // Build authorization URL
        var components = URLComponents(string: "https://api.notion.com/v1/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: NotionSettings.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "owner", value: "user"),
            URLQueryItem(name: "redirect_uri", value: NotionSettings.redirectURI),
        ]
        guard let authURL = components.url else {
            completion(.failure(NotionError.oauthFailed("Invalid OAuth URL")))
            return
        }

        // Start local server to receive token forwarded by public OAuth server
        localServer = LocalOAuthServer(port: 9988) { [weak self] result in
            guard let self = self else { return }
            self.localServer = nil
            switch result {
            case .failure(let err):
                DispatchQueue.main.async { self.oauthCompletion?(.failure(err)) }
            case .success(let tokenDict):
                // Save token info received from public server
                if let token = tokenDict["access_token"] {
                    NotionSettings.accessToken = token
                }
                if let name = tokenDict["workspace_name"] {
                    NotionSettings.workspaceName = name
                }
                if let wsId = tokenDict["workspace_id"] {
                    UserDefaults.standard.set(wsId, forKey: NotionSettings.workspaceIdKey)
                }
                if let botId = tokenDict["bot_id"] {
                    UserDefaults.standard.set(botId, forKey: NotionSettings.botIdKey)
                }
                DispatchQueue.main.async { self.oauthCompletion?(.success(())) }
            }
        }
        localServer?.start()

        // Open browser
        NSWorkspace.shared.open(authURL)
    }

    // MARK: - Exchange Code for Token

    func exchangeCodeForToken(code: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let url = URL(string: "https://api.notion.com/v1/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")

        // Basic auth: base64(clientId:clientSecret)
        let credentials = "\(NotionSettings.clientId):\(NotionSettings.clientSecret)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": NotionSettings.redirectURI,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(NotionError.oauthFailed("Invalid token response")))
                return
            }
            if let token = json["access_token"] as? String {
                NotionSettings.accessToken = token
                NotionSettings.workspaceName = (json["workspace_name"] as? String) ?? ""
                if let workspaceId = json["workspace_id"] as? String {
                    UserDefaults.standard.set(workspaceId, forKey: NotionSettings.workspaceIdKey)
                }
                if let botId = json["bot_id"] as? String {
                    UserDefaults.standard.set(botId, forKey: NotionSettings.botIdKey)
                }
                completion(.success(()))
            } else {
                let msg = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "Unknown error"
                completion(.failure(NotionError.oauthFailed(msg)))
            }
        }.resume()
    }

    // MARK: - Create Bug Page

    func createBugPage(input: NotionBugInput, completion: @escaping (Result<String, Error>) -> Void) {
        guard NotionSettings.isAuthorized else {
            completion(.failure(NotionError.notAuthorized))
            return
        }

        // Step 1: Fetch the owner user ID if not cached
        let proceed = { [weak self] in
            guard let self = self else { return }
            // Step 2: Upload image
            self.uploadImage(input.image) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .failure(let err): completion(.failure(err))
                case .success(let fileInfo): self.createPage(input: input, imageFileInfo: fileInfo, completion: completion)
                }
            }
        }

        if NotionSettings.ownerUserId.isEmpty {
            fetchOwnerUserId { _ in proceed() }
        } else {
            proceed()
        }
    }

    /// Fetch the real Notion user ID (person) who authorized this integration.
    /// GET /v1/users/me returns the bot; the owner.user.id inside it is the real person.
    private func fetchOwnerUserId(completion: @escaping (String?) -> Void) {
        let url = URL(string: "\(baseURL)/users/me")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(NotionSettings.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bot = json["bot"] as? [String: Any],
                  let owner = bot["owner"] as? [String: Any],
                  let user = owner["user"] as? [String: Any],
                  let userId = user["id"] as? String else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            NotionSettings.ownerUserId = userId
            DispatchQueue.main.async { completion(userId) }
        }.resume()
    }

    // MARK: - Image Upload

    private struct FileInfo {
        let fileUploadId: String
        let uploadUrl: String  // URL returned by create, used to send file data
    }

    private func uploadImage(_ image: NSImage, completion: @escaping (Result<FileInfo, Error>) -> Void) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            completion(.failure(NotionError.imageConversionFailed))
            return
        }

        createFileUpload(filename: "screenshot.png", contentType: "image/png") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err): completion(.failure(err))
            case .success(let info):
                self.sendFileUpload(fileUploadId: info.fileUploadId, uploadUrl: info.uploadUrl, data: pngData) { result in
                    switch result {
                    case .failure(let err): completion(.failure(err))
                    case .success: completion(.success(info))
                    }
                }
            }
        }
    }

    private func createFileUpload(filename: String, contentType: String, completion: @escaping (Result<FileInfo, Error>) -> Void) {
        let url = URL(string: "\(baseURL)/file_uploads")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(NotionSettings.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["filename": filename, "content_type": contentType, "mode": "single_part"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uploadId = json["id"] as? String else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                DispatchQueue.main.async { completion(.failure(NotionError.apiError("Create upload failed: \(body)"))) }
                return
            }
            let uploadUrl = json["upload_url"] as? String ?? "\(self.baseURL)/file_uploads/\(uploadId)/send"
            DispatchQueue.main.async { completion(.success(FileInfo(fileUploadId: uploadId, uploadUrl: uploadUrl))) }
        }.resume()
    }

    /// Send file data to the upload_url returned by createFileUpload.
    /// Endpoint: POST /v1/file_uploads/{file_upload_id}/send  (multipart/form-data)
    private func sendFileUpload(fileUploadId: String, uploadUrl: String, data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        // Use the upload_url from create response; fall back to constructed URL
        let url = URL(string: uploadUrl) ?? URL(string: "\(baseURL)/file_uploads/\(fileUploadId)/send")!
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(NotionSettings.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"screenshot.png\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        // Use a dedicated session with longer timeouts for upload
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)

        // Use uploadTask instead of dataTask for better large-body handling
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("snipshot_upload_\(UUID().uuidString).bin")
        do {
            try body.write(to: tempFile)
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        }

        session.uploadTask(with: request, fromFile: tempFile) { data, response, error in
            try? FileManager.default.removeItem(at: tempFile)
            if let error = error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode >= 200 && statusCode < 300 {
                DispatchQueue.main.async { completion(.success(())) }
            } else {
                let respBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                DispatchQueue.main.async { completion(.failure(NotionError.apiError("Send file upload failed (HTTP \(statusCode)): \(respBody)"))) }
            }
        }.resume()
    }

    // MARK: - Create Page

    private func createPage(input: NotionBugInput, imageFileInfo: FileInfo, completion: @escaping (Result<String, Error>) -> Void) {
        let url = URL(string: "\(baseURL)/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(NotionSettings.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Properties — 提出人 uses the real Notion person ID, 对接PD left empty
        var properties: [String: Any] = [
            "名称": ["title": [["text": ["content": input.title]]]],
            "模块": ["select": ["name": "Bug"]],
            "状态": ["select": ["name": "待讨论"]],
        ]
        if !input.priority.isEmpty    { properties["优先级"]  = ["select": ["name": input.priority]] }
        if !input.feedbackType.isEmpty { properties["反馈类型"] = ["select": ["name": input.feedbackType]] }

        // 提出人: use the real person user ID (not the bot)
        let ownerUserId = NotionSettings.ownerUserId
        if !ownerUserId.isEmpty {
            properties["提出人"] = ["people": [["object": "user", "id": ownerUserId]]]
        }
        // 对接 PD: intentionally left empty (do not set)

        // Children blocks: notes as text paragraph + screenshot image
        var children: [[String: Any]] = []

        // Add notes as page body text (paragraph block)
        if !input.notes.isEmpty {
            let textBlock: [String: Any] = [
                "object": "block", "type": "paragraph",
                "paragraph": ["rich_text": [["type": "text", "text": ["content": input.notes]]]]
            ]
            children.append(textBlock)
        }

        // Add screenshot image block
        let imageBlock: [String: Any] = [
            "object": "block", "type": "image",
            "image": ["type": "file_upload", "file_upload": ["id": imageFileInfo.fileUploadId]]
        ]
        children.append(imageBlock)

        let body: [String: Any] = [
            "parent": ["database_id": NotionSettings.databaseId],
            "properties": properties,
            "children": children
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(.failure(NotionError.apiError("Invalid response"))) }
                return
            }
            if let pageUrl = json["url"] as? String {
                DispatchQueue.main.async { completion(.success(pageUrl)) }
            } else {
                let msg = (json["message"] as? String) ?? String(data: data, encoding: .utf8) ?? "Unknown error"
                DispatchQueue.main.async { completion(.failure(NotionError.apiError(msg))) }
            }
        }.resume()
    }
}

// MARK: - Local OAuth Callback Server
// Listens on localhost:9988 for two types of requests:
//   POST /notion/token  — token forwarded by the public OAuth server after code exchange
//   GET  /notion/callback?code=xxx — fallback if redirect goes directly to localhost

class LocalOAuthServer {
    private let port: UInt16
    private var serverSocket: Int32 = -1
    private var isRunning = false
    // tokenCallback receives the full token JSON dict
    private let tokenCallback: (Result<[String: String], Error>) -> Void

    init(port: UInt16, tokenCallback: @escaping (Result<[String: String], Error>) -> Void) {
        self.port = port
        self.tokenCallback = tokenCallback
    }

    func start() {
        isRunning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runServer()
        }
    }

    func stop() {
        isRunning = false
        if serverSocket >= 0 { close(serverSocket); serverSocket = -1 }
    }

    private func runServer() {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            tokenCallback(.failure(NotionError.oauthFailed("Cannot create socket")))
            return
        }

        var opt: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            tokenCallback(.failure(NotionError.oauthFailed("Cannot bind to port \(port)")))
            close(serverSocket)
            return
        }

        listen(serverSocket, 5)

        // Keep accepting connections until we get a valid token
        while isRunning {
            let clientSocket = accept(serverSocket, nil, nil)
            guard clientSocket >= 0 else { break }
            handleConnection(clientSocket)
        }
        if serverSocket >= 0 { close(serverSocket); serverSocket = -1 }
    }

    private func handleConnection(_ clientSocket: Int32) {
        defer { close(clientSocket) }

        // Read up to 8KB
        let bufSize = 8192
        let bufPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { bufPtr.deallocate() }
        var totalRead = 0
        while totalRead < bufSize {
            let n = Darwin.read(clientSocket, bufPtr.advanced(by: totalRead), bufSize - totalRead)
            if n <= 0 { break }
            totalRead += n
            // Stop reading once we have the full HTTP request (double CRLF)
            let partial = String(bytes: UnsafeBufferPointer(start: bufPtr, count: totalRead), encoding: .utf8) ?? ""
            if partial.contains("\r\n\r\n") { break }
        }
        let request = String(bytes: UnsafeBufferPointer(start: bufPtr, count: totalRead), encoding: .utf8) ?? ""

        // CORS preflight
        if request.hasPrefix("OPTIONS") {
            let resp = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, GET, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n"
            write(clientSocket, resp, resp.utf8.count)
            return
        }

        // POST /notion/token — token forwarded by public server
        if request.hasPrefix("POST /notion/token") {
            // Extract JSON body (after \r\n\r\n)
            let okResp = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
            write(clientSocket, okResp, okResp.utf8.count)

            if let bodyRange = request.range(of: "\r\n\r\n"),
               let bodyData = String(request[bodyRange.upperBound...]).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: String],
               let token = json["access_token"], !token.isEmpty {
                isRunning = false
                tokenCallback(.success(json))
            }
            return
        }

        // GET /notion/callback?code=xxx — fallback direct localhost redirect
        if request.hasPrefix("GET /notion/callback?") {
            let queryPart = String(request.dropFirst("GET /notion/callback?".count))
            let params = queryPart.components(separatedBy: " ").first ?? ""
            var code: String? = nil
            for param in params.components(separatedBy: "&") {
                let kv = param.components(separatedBy: "=")
                if kv.count == 2 && kv[0] == "code" {
                    code = kv[1].removingPercentEncoding
                }
            }
            let html = "<html><body style='font-family:sans-serif;text-align:center;padding:60px'><h2>✅ Notion 授权成功！</h2><p>正在处理，请稍候...</p></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            write(clientSocket, resp, resp.utf8.count)
            if let code = code {
                // Exchange code for token directly on localhost
                NotionService.shared.exchangeCodeForToken(code: code) { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .success:
                        self.isRunning = false
                        // Build token dict from saved settings
                        let tokenDict: [String: String] = [
                            "access_token": NotionSettings.accessToken,
                            "workspace_name": NotionSettings.workspaceName,
                            "workspace_id": UserDefaults.standard.string(forKey: NotionSettings.workspaceIdKey) ?? "",
                            "bot_id": UserDefaults.standard.string(forKey: NotionSettings.botIdKey) ?? "",
                        ]
                        self.tokenCallback(.success(tokenDict))
                    case .failure(let err):
                        self.tokenCallback(.failure(err))
                    }
                }
            }
            return
        }

        // Unknown request — 404
        let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        write(clientSocket, notFound, notFound.utf8.count)
    }
}

// MARK: - Notion Errors

enum NotionError: LocalizedError {
    case notAuthorized
    case imageConversionFailed
    case apiError(String)
    case oauthFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Please connect your Notion account first in Settings → Notion."
        case .imageConversionFailed:
            return "Failed to convert screenshot to PNG."
        case .apiError(let msg):
            return "Notion API error: \(msg)"
        case .oauthFailed(let msg):
            return "Notion OAuth error: \(msg)"
        }
    }
}
