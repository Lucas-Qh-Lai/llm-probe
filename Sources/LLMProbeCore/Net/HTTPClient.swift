import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A fully resolved HTTP request. Secrets are already attached at this point, so
/// this type is treated as sensitive and never logged directly.
public struct HTTPRequestSpec: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 45) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponsePayload: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public var durationMS: Double

    public var bodyText: String { String(data: body, encoding: .utf8) ?? "" }

    public var isSuccess: Bool { (200..<300).contains(status) }

    public func headerValue(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// One incremental slice of a streamed response.
public struct HTTPStreamChunk: Sendable {
    public var data: Data
    public var elapsedMS: Double
}

public struct HTTPStreamSummary: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var firstChunkMS: Double?
    public var totalMS: Double
    public var byteCount: Int

    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// URLSession wrapper with a small streaming API.
///
/// * `send` buffers the whole response (used by metadata and validation probes).
/// * `stream` yields chunks as they arrive (used for TTFT and output speed).
public final class HTTPClient: @unchecked Sendable {
    public static let shared = HTTPClient()

    private let session: URLSession
    private let streamingSession: URLSession

    public init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? .ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
        let streamingConfig = config.copy() as? URLSessionConfiguration ?? config
        streamingSession = URLSession(configuration: streamingConfig)
    }

    // MARK: - Buffered

    public func send(_ spec: HTTPRequestSpec) async throws -> HTTPResponsePayload {
        var request = URLRequest(url: spec.url, timeoutInterval: spec.timeout)
        request.httpMethod = spec.method
        request.httpBody = spec.body
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (key, value) in spec.headers { request.setValue(value, forHTTPHeaderField: key) }

        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = Date().timeIntervalSince(started) * 1000
            let http = response as? HTTPURLResponse
            return HTTPResponsePayload(
                status: http?.statusCode ?? 0,
                headers: Self.normaliseHeaders(http?.allHeaderFields),
                body: data,
                durationMS: elapsed
            )
        } catch let error as URLError {
            throw HTTPClientError.transport(error)
        } catch {
            throw HTTPClientError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Streaming

    public func stream(_ spec: HTTPRequestSpec) -> HTTPStream {
        var request = URLRequest(url: spec.url, timeoutInterval: spec.timeout)
        request.httpMethod = spec.method
        request.httpBody = spec.body
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (key, value) in spec.headers { request.setValue(value, forHTTPHeaderField: key) }
        return HTTPStream(configuration: streamingSession.configuration, request: request)
    }

    static func normaliseHeaders(_ raw: [AnyHashable: Any]?) -> [String: String] {
        guard let raw else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in raw {
            guard let key = key as? String else { continue }
            result[key] = "\(value)"
        }
        return result
    }
}

/// Human description for a transport failure, owned by the app instead of
/// `URLError.localizedDescription`.
///
/// Foundation localises that string with the *system* language, which is the
/// opposite of what the report needs: a probe run in English on a Chinese Mac
/// (or the other way round, which is common when the language is switched in
/// Settings) would otherwise mix two languages inside one line.
func transportMessage(for error: URLError) -> String {
    switch error.code {
    case .timedOut:
        return L10n.pick(zh: "请求超时：在设定的时限内没有收到响应。", en: "Request timed out: no response inside the configured limit.")
    case .cannotFindHost:
        return L10n.pick(zh: "找不到主机：域名无法解析。", en: "Host not found: the domain does not resolve.")
    case .cannotConnectToHost:
        return L10n.pick(zh: "无法连接主机：端口、代理或本地服务未就绪。", en: "Could not connect to the host: port, proxy or local server not ready.")
    case .dnsLookupFailed:
        return L10n.pick(zh: "DNS 解析失败。", en: "DNS lookup failed.")
    case .networkConnectionLost:
        return L10n.pick(zh: "网络连接中断。", en: "The network connection was lost.")
    case .notConnectedToInternet:
        return L10n.pick(zh: "当前设备没有可用网络。", en: "This machine has no network connection.")
    case .secureConnectionFailed:
        return L10n.pick(zh: "TLS 握手失败，无法建立安全连接。", en: "TLS handshake failed; a secure connection could not be established.")
    case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
        return L10n.pick(zh: "服务器证书不受信任或尚未生效。", en: "The server certificate is untrusted or not yet valid.")
    case .serverCertificateHasBadDate:
        return L10n.pick(zh: "服务器证书已过期。", en: "The server certificate has expired.")
    case .appTransportSecurityRequiresSecureConnection:
        return L10n.pick(zh: "系统策略要求使用 HTTPS 连接。", en: "App Transport Security requires a secure (HTTPS) connection.")
    case .cancelled:
        return L10n.pick(zh: "请求已取消。", en: "The request was cancelled.")
    case .userAuthenticationRequired:
        return L10n.pick(zh: "上游要求先完成认证。", en: "The upstream requires authentication first.")
    default:
        return L10n.pick(zh: "网络错误（URLError \(error.code.rawValue)）。", en: "Network error (URLError \(error.code.rawValue)).")
    }
}

public enum HTTPClientError: Error, Sendable {
    case transport(URLError)
    case unknown(String)

    public var failure: ProbeFailure {
        switch self {
        case .transport(let urlError):
            let category: ProbeFailure.Category
            switch urlError.code {
            case .timedOut: category = .timeout
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
                 .notConnectedToInternet, .secureConnectionFailed, .serverCertificateUntrusted,
                 .appTransportSecurityRequiresSecureConnection:
                category = .network
            case .cancelled: category = .cancelled
            default: category = .network
            }
            return ProbeFailure(category: category, message: transportMessage(for: urlError))
        case .unknown(let message):
            return ProbeFailure(category: .network, message: message)
        }
    }
}

/// A live streamed response: `chunks` for the bytes, `summary()` for the outcome.
public final class HTTPStream: @unchecked Sendable {
    public let chunks: AsyncThrowingStream<HTTPStreamChunk, Error>

    private let controller: StreamController

    init(configuration: URLSessionConfiguration, request: URLRequest) {
        let controller = StreamController(configuration: configuration, request: request)
        self.controller = controller
        self.chunks = controller.chunks
    }

    /// Aborts the request. Used by validation probes that only need to learn
    /// whether a request was accepted.
    public func cancel() {
        controller.cancel()
    }

    /// Resolves once the response has finished (or failed).
    public func summary() async -> HTTPStreamSummary? {
        await controller.waitForSummary()
    }
}

/// Owns one streaming URLSession. A per-stream session is required because
/// `URLSession.dataTask(with:)` does not deliver delegate callbacks unless the
/// session itself was created with that delegate.
private final class StreamController: @unchecked Sendable {
    let chunks: AsyncThrowingStream<HTTPStreamChunk, Error>

    private let state: StreamState
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(configuration: URLSessionConfiguration, request: URLRequest) {
        let state = StreamState()
        self.state = state

        var captured: AsyncThrowingStream<HTTPStreamChunk, Error>.Continuation!
        self.chunks = AsyncThrowingStream { captured = $0 }
        let continuation = captured!

        let delegate = StreamDelegate(
            onChunk: { data, elapsedMS in
                continuation.yield(HTTPStreamChunk(data: data, elapsedMS: elapsedMS))
            },
            onFinish: { outcome in
                switch outcome {
                case .success(let summary):
                    state.resolve(summary)
                    continuation.finish()
                case .failure(let error):
                    state.resolve(nil)
                    continuation.finish(throwing: error)
                }
            }
        )

        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        self.session = session
        let task = session.dataTask(with: request)
        delegate.task = task
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
    }

    func waitForSummary() async -> HTTPStreamSummary? {
        await state.wait()
    }

    deinit {
        session?.invalidateAndCancel()
    }
}

private enum StreamOutcome {
    case success(HTTPStreamSummary)
    case failure(Error)
}

private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var summary: HTTPStreamSummary?
    private var isResolved = false
    private var waiters: [CheckedContinuation<HTTPStreamSummary?, Never>] = []
    private var delegateRef: AnyObject?

    func resolve(_ value: HTTPStreamSummary?) {
        lock.lock()
        summary = value
        isResolved = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(returning: value) }
    }

    func wait() async -> HTTPStreamSummary? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isResolved {
                let value = summary
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onChunk: (Data, Double) -> Void
    private let onFinish: (StreamOutcome) -> Void

    private let startedAt = Date()
    private var status = 0
    private var headers: [String: String] = [:]
    private var firstChunkMS: Double?
    private var byteCount = 0
    private var didFinish = false
    private var buffer = Data()

    weak var task: URLSessionDataTask?
    weak var session: URLSession?

    init(onChunk: @escaping (Data, Double) -> Void, onFinish: @escaping (StreamOutcome) -> Void) {
        self.onChunk = onChunk
        self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        headers = HTTPClient.normaliseHeaders((response as? HTTPURLResponse)?.allHeaderFields)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let elapsed = Date().timeIntervalSince(startedAt) * 1000
        if firstChunkMS == nil { firstChunkMS = elapsed }
        byteCount += data.count
        // Non-2xx bodies are error payloads: buffer them so the classifier can read them.
        if status >= 400 {
            buffer.append(data)
            return
        }
        onChunk(data, elapsed)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error: error)
    }

    private func finish(error: Error?) {
        guard !didFinish else { return }
        didFinish = true
        let totalMS = Date().timeIntervalSince(startedAt) * 1000
        defer {
            // Release the per-stream session (and its strongly held delegate).
            if let session { DispatchQueue.global().async { session.finishTasksAndInvalidate() } }
        }
        if let error {
            if status >= 400, !buffer.isEmpty {
                // Keep the upstream error body: it is more useful than the transport error.
                let summary = HTTPStreamSummary(status: status, headers: headers, firstChunkMS: firstChunkMS, totalMS: totalMS, byteCount: byteCount)
                _ = summary
                onFinish(.failure(HTTPStreamBodyError(summary: summary, body: buffer)))
                return
            }
            onFinish(.failure(error))
            return
        }
        if status >= 400 {
            let summary = HTTPStreamSummary(status: status, headers: headers, firstChunkMS: firstChunkMS, totalMS: totalMS, byteCount: byteCount)
            onFinish(.failure(HTTPStreamBodyError(summary: summary, body: buffer)))
            return
        }
        let summary = HTTPStreamSummary(status: status, headers: headers, firstChunkMS: firstChunkMS, totalMS: totalMS, byteCount: byteCount)
        onFinish(.success(summary))
    }
}

/// Error carrying an upstream HTTP error body so the classifier can categorise it.
public struct HTTPStreamBodyError: Error, Sendable {
    public var summary: HTTPStreamSummary
    public var body: Data

    public var bodyText: String { String(data: body, encoding: .utf8) ?? "" }
}
