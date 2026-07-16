import Foundation
import Cocoa

typealias AIMessage = AIConversationMessage

final class AIRequestHandle {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionTask?
    private var cancelled = false

    fileprivate func attach(session: URLSession, task: URLSessionTask) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            session.invalidateAndCancel()
            return
        }
        self.session = session
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    fileprivate func finish() {
        lock.lock()
        let session = self.session
        self.task = nil
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
    }
}

private final class AIStreamingDelegate: NSObject, URLSessionDataDelegate {
    private var parser: AIStreamParser
    private var content = ""
    private var errorData = Data()
    private var response: HTTPURLResponse?
    private let onChunk: (String) -> Void
    private let completion: (Result<String, Error>) -> Void
    private let handle: AIRequestHandle
    private let logPrefix: String
    private let lock = NSLock()
    private var completed = false

    init(protocol streamProtocol: AIStreamProtocol, handle: AIRequestHandle, logPrefix: String, onChunk: @escaping (String) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        parser = AIStreamParser(streamProtocol: streamProtocol)
        self.handle = handle
        self.logPrefix = logPrefix
        self.onChunk = onChunk
        self.completion = completion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let status = response?.statusCode, !(200...299).contains(status) {
            errorData.append(data)
            return
        }
        do {
            let result = try parser.append(data)
            for delta in result.deltas {
                content += delta
                let accumulated = content
                DispatchQueue.main.async { [onChunk] in onChunk(accumulated) }
            }
            if result.completed { finish(.success(content)) }
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                finish(.failure(AIProviderError.cancelled), notify: false)
            } else {
                finish(.failure(AIProviderError.transport(error.localizedDescription)))
            }
            return
        }
        if let response, !(200...299).contains(response.statusCode) {
            finish(.failure(AIErrorParser.httpError(status: response.statusCode, data: errorData, response: response)))
        } else if content.isEmpty {
            finish(.failure(AIProviderError.invalidResponse("The provider returned no text.")))
        } else {
            finish(.success(content))
        }
    }

    private func finish(_ result: Result<String, Error>, notify: Bool = true) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        handle.finish()
        if notify {
            DispatchQueue.main.async { [completion, logPrefix] in
                if case .failure(let error) = result { logMessage("\(logPrefix): \(error.localizedDescription)") }
                completion(result)
            }
        }
    }
}

final class AIService {
    static let shared = AIService()
    private init() {}

    private let maxImageDimension: CGFloat = 2048
    private let imageQuality: CGFloat = 0.7

    func prepareImageDataURL(from image: NSImage) -> String? {
        let originalSize = image.size
        guard originalSize.width > 0 && originalSize.height > 0 else { return nil }
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0
        var targetSize = NSSize(width: originalSize.width / scaleFactor, height: originalSize.height / scaleFactor)
        let maxDim = max(targetSize.width, targetSize.height)
        if maxDim > maxImageDimension {
            let scale = maxImageDimension / maxDim
            targetSize = NSSize(width: targetSize.width * scale, height: targetSize.height * scale)
        }
        targetSize.width = max(1, round(targetSize.width))
        targetSize.height = max(1, round(targetSize.height))
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(targetSize.width), pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: NSRect(origin: .zero, size: originalSize), operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: imageQuality]) else { return nil }
        logMessage("AI: prepared image \(Int(targetSize.width))x\(Int(targetSize.height)), \(jpegData.count / 1024)KB")
        return "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
    }

    @discardableResult
    func streamChat(
        messages: [AIMessage],
        logPrefix: String = "AI",
        onChunk: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> AIRequestHandle? {
        let configuration = AISettings.configuration
        let apiKey = AISettings.apiKey
        do {
            let built = try AIRequestBuilder.build(
                configuration: configuration,
                apiKey: apiKey,
                request: AIProviderRequest(messages: messages, stream: true)
            )
            let handle = AIRequestHandle()
            let delegate = AIStreamingDelegate(protocol: built.streamProtocol, handle: handle, logPrefix: logPrefix, onChunk: onChunk, completion: completion)
            let sessionConfig = URLSessionConfiguration.default
            sessionConfig.timeoutIntervalForRequest = 120
            let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: built.urlRequest)
            handle.attach(session: session, task: task)
            logMessage("\(logPrefix): streaming with \(configuration.provider.displayName), model=\(configuration.model)")
            task.resume()
            return handle
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return nil
        }
    }

    func listModels(configuration: AIProviderConfiguration, apiKey: String, completion: @escaping (Result<[AIModelDescriptor], Error>) -> Void) {
        do {
            let request = try AIRequestBuilder.buildModelList(configuration: configuration, apiKey: apiKey)
            fetchModelPage(request: request, configuration: configuration, accumulated: [], completion: completion)
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }

    private func fetchModelPage(request: URLRequest, configuration: AIProviderConfiguration, accumulated: [AIModelDescriptor], completion: @escaping (Result<[AIModelDescriptor], Error>) -> Void) {
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(AIProviderError.transport(error.localizedDescription))) }
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let providerError = AIErrorParser.httpError(status: http.statusCode, data: data, response: http)
                DispatchQueue.main.async { completion(.failure(providerError)) }
                return
            }
            guard let data else {
                DispatchQueue.main.async { completion(.failure(AIProviderError.invalidResponse("The provider returned no model list."))) }
                return
            }
            do {
                let page = try AIModelParser.parsePage(data: data, provider: configuration.provider)
                let models = accumulated + page.models
                if configuration.provider == .anthropic, page.hasMore, let lastID = page.lastID,
                   var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) {
                    var query = components.queryItems ?? []
                    query.removeAll { $0.name == "after_id" }
                    query.append(URLQueryItem(name: "after_id", value: lastID))
                    components.queryItems = query
                    guard let url = components.url else { throw AIProviderError.invalidResponse("Anthropic returned an invalid model cursor.") }
                    var next = request
                    next.url = url
                    self?.fetchModelPage(request: next, configuration: configuration, accumulated: models, completion: completion)
                } else {
                    let unique = Dictionary(grouping: models, by: \.id).compactMap { $0.value.first }
                        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                    DispatchQueue.main.async { completion(.success(unique)) }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    func testConnection(configuration: AIProviderConfiguration, apiKey: String, completion: @escaping (String?) -> Void) {
        do {
            let built = try AIRequestBuilder.build(
                configuration: configuration,
                apiKey: apiKey,
                request: AIProviderRequest(messages: [.text(role: .user, content: "Reply with OK.")], outputTokenLimit: 32, stream: false)
            )
            URLSession.shared.dataTask(with: built.urlRequest) { data, response, error in
                var message: String?
                if let error {
                    message = AIProviderError.transport(error.localizedDescription).localizedDescription
                } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    message = AIErrorParser.httpError(status: http.statusCode, data: data, response: http).localizedDescription
                } else if let data {
                    do { _ = try AIResponseParser.parseText(data: data, responseProtocol: built.responseProtocol) }
                    catch { message = error.localizedDescription }
                } else {
                    message = "The provider returned no response."
                }
                DispatchQueue.main.async { completion(message) }
            }.resume()
        } catch {
            DispatchQueue.main.async { completion(error.localizedDescription) }
        }
    }

    func testConnection(completion: @escaping (String?) -> Void) {
        testConnection(configuration: AISettings.configuration, apiKey: AISettings.apiKey, completion: completion)
    }
}
