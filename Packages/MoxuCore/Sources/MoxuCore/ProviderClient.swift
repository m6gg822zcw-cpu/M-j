import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct HTTPResult: Sendable {
    public var data: Data, status: Int
    public init(data: Data, status: Int = 200) {
        self.data = data
        self.status = status
    }
}
public protocol HTTPTransport: Sendable { func send(_ request: PreparedRequest) async throws -> HTTPResult }
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if task.originalRequest?.httpMethod == "GET", request.url?.scheme == "https",
            request.url?.host == task.originalRequest?.url?.host
        {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
public actor URLTransport: HTTPTransport {
    private let session: URLSession
    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 180
        c.timeoutIntervalForResource = 360
        c.httpMaximumConnectionsPerHost = 2
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c, delegate: RedirectGuard(), delegateQueue: nil)
    }
    public func send(_ request: PreparedRequest) async throws -> HTTPResult {
        try Task.checkCancellation()
        let (file, response) = try await session.download(for: request.urlRequest())
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else { throw StudioError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else { throw StudioError.http(http.statusCode) }
        let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw StudioError.invalid("服务响应超过64MB。") }
        return HTTPResult(data: try Data(contentsOf: file, options: .mappedIfSafe), status: http.statusCode)
    }
}
public actor ProviderClient {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLTransport()) { self.transport = transport }
    public func complete(profile: APIProfile, token: String, prompt: String, images: [ReferenceImage] = []) async throws
        -> String
    {
        let req = try RequestBuilder.text(profile: profile, token: token, prompt: prompt, images: images)
        let result = try await transport.send(req)
        guard (200..<300).contains(result.status) else { throw StudioError.http(result.status) }
        guard let json = try JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            throw StudioError.emptyResponse
        }
        let text: String?
        switch profile.kind {
        case .chat:
            let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            text =
                message?["content"] as? String
                ?? (message?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(
                    separator: "\n")
        case .responses:
            let messages = (json["output"] as? [[String: Any]]) ?? []
            text =
                json["output_text"] as? String
                ?? messages.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.filter {
                    $0["type"] as? String == "output_text"
                }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .anthropic:
            text = (json["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .geminiText:
            text = ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"].flatMap {
                $0 as? [[String: Any]]
            }?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        default: throw StudioError.invalid("此连接不是文本模型。")
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudioError.emptyResponse
        }
        return text
    }
    public func generate(_ request: PreparedRequest, profile: APIProfile) async throws -> Data {
        let r = try await transport.send(request)
        guard (200..<300).contains(r.status) else { throw StudioError.http(r.status) }
        var data = r.data
        if data.starts(with: [0x50, 0x4b]) {
            data = try ZIPArchive(data: data).firstImage()
        } else if !Self.isImage(data) {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StudioError.emptyResponse
            }
            if let rows = object["data"] as? [[String: Any]], let first = rows.first {
                if let b64 = first["b64_json"] as? String, let decoded = Data(base64Encoded: b64) {
                    data = decoded
                } else if let s = first["url"] as? String {
                    if s.hasPrefix("data:image/"), let comma = s.firstIndex(of: ","),
                        let decoded = Data(base64Encoded: String(s[s.index(after: comma)...]))
                    {
                        data = decoded
                    } else {
                        guard let u = URL(string: s), u.user == nil, u.password == nil,
                            u.scheme == "https" || (u.scheme == "http" && profile.allowHTTP)
                        else { throw StudioError.invalid("图片地址不是受支持的 HTTP(S) URL。") }
                        var download = PreparedRequest(url: u, headers: [:], body: Data(), redactedJSON: "{}")
                        download.method = "GET"
                        let response = try await transport.send(download)
                        guard (200..<300).contains(response.status) else { throw StudioError.http(response.status) }
                        data = response.data
                    }
                } else {
                    throw StudioError.emptyResponse
                }
            } else if let candidates = object["candidates"] as? [[String: Any]],
                let content = candidates.first?["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]],
                let inline = parts.compactMap({
                    $0["inlineData"] as? [String: Any] ?? $0["inline_data"] as? [String: Any]
                }).first, let b64 = inline["data"] as? String, let decoded = Data(base64Encoded: b64)
            {
                data = decoded
            } else {
                throw StudioError.emptyResponse
            }
        }
        guard Self.isImage(data) else { throw StudioError.invalid("服务返回的不是有效 PNG、JPEG 或 WebP 图片。") }
        return data
    }
    public static func isImage(_ data: Data) -> Bool {
        data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) || data.starts(with: [255, 216, 255])
            || (data.count > 12 && data.prefix(4) == Data("RIFF".utf8) && data.subdata(in: 8..<12) == Data("WEBP".utf8))
    }
    public func models(profile p: APIProfile, token: String) async throws -> [String] {
        guard p.kind != .novelAI else {
            return ["nai-diffusion-4-5-full", "nai-diffusion-4-5-curated", "nai-diffusion-4-full"]
        }
        var headers: [String: String] = [:]
        switch p.kind {
        case .geminiText, .geminiImage: headers["x-goog-api-key"] = token
        case .anthropic:
            headers["x-api-key"] = token
            headers["anthropic-version"] = "2023-06-01"
        default: if !token.isEmpty { headers["Authorization"] = "Bearer " + token }
        }
        var req = PreparedRequest(
            url: try RequestBuilder.endpoint(p, suffix: "models"), headers: headers, body: Data(), redactedJSON: "{}")
        req.method = "GET"
        let response = try await transport.send(req)
        guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw StudioError.emptyResponse
        }
        return
            ((json["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
            ?? (json["models"] as? [[String: Any]])?.compactMap {
                ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "")
            } ?? []).sorted()
    }
}
