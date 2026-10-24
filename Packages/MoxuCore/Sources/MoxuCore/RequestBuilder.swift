import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct ReferenceImage: Sendable {
    public var data: Data, mime: String, label: String
    public init(data: Data, mime: String = "image/png", label: String = "") {
        self.data = data
        self.mime = mime
        self.label = label
    }
    public var dataURL: String { "data:\(mime);base64,\(data.base64EncodedString())" }
}
public struct PreparedRequest: Sendable {
    public var url: URL, headers: [String: String], body: Data
    public var method = "POST"
    public var redactedJSON: String
    public init(url: URL, headers: [String: String], body: Data, redactedJSON: String) {
        self.url = url
        self.headers = headers
        self.body = body
        self.redactedJSON = redactedJSON
    }
    public func urlRequest() -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = method == "GET" ? nil : body
        r.timeoutInterval = 300
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }
}
public enum RequestBuilder {
    public static func endpoint(_ profile: APIProfile, suffix: String, override: String? = nil) throws -> URL {
        let base = (override?.isEmpty == false ? override! : profile.baseURL).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: base), let scheme = c.scheme, ["https", "http"].contains(scheme),
            c.host != nil, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil
        else { throw StudioError.invalid("API 地址须为不含密钥、查询参数或账号密码的 HTTP(S) 地址。") }
        guard scheme == "https" || profile.allowHTTP else { throw StudioError.invalid("此连接未启用局域网 HTTP。") }
        if override?.isEmpty != false {
            var path = c.path
            while path.hasSuffix("/") { path.removeLast() }
            let known = [
                "/chat/completions", "/responses", "/messages", "/images/generations", "/images/edits",
                "/ai/generate-image",
            ]
            if let last = known.first(where: { path.hasSuffix($0) }) { path.removeLast(last.count) }
            if [.geminiText, .geminiImage].contains(profile.kind),
                let range = path.range(of: #"/models/[^/]+:generateContent$"#, options: .regularExpression)
            {
                path.removeSubrange(range)
            }
            c.path = path + "/" + suffix
        }
        guard let url = c.url else { throw StudioError.invalid("API 地址无效。") }
        return url
    }
    private static func jsonRequest(
        _ profile: APIProfile, suffix: String, payload: [String: Any], token: String, override: String? = nil
    ) throws -> PreparedRequest {
        var headers = ["Content-Type": "application/json"]
        if profile.kind == .anthropic { headers["anthropic-version"] = "2023-06-01" }
        if !token.isEmpty {
            switch profile.kind {
            case .geminiText, .geminiImage: headers["x-goog-api-key"] = token
            case .anthropic:
                headers["x-api-key"] = token
                headers["anthropic-version"] = "2023-06-01"
            default: headers["Authorization"] = "Bearer " + token
            }
        }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return PreparedRequest(
            url: try endpoint(profile, suffix: suffix, override: override), headers: headers, body: body,
            redactedJSON: try auditJSON(payload))
    }
    private static func auditJSON(_ object: Any) throws -> String {
        func redact(_ value: Any, key: String = "") -> Any {
            if ["authorization", "api_key", "apikey", "token", "x-api-key", "x-goog-api-key"].contains(key.lowercased())
            {
                return "[已隐藏]"
            }
            if let s = value as? String,
                s.hasPrefix("data:") || key == "data" || key == "image" || key == "director_reference_images"
                    || (s.count > 2000 && key.lowercased().contains("image"))
            {
                return "[图片数据 \(s.count) 字符]"
            }
            if let a = value as? [Any] { return a.map { redact($0, key: key) } }
            if let o = value as? [String: Any] {
                return o.mapValues { $0 }.reduce(into: [String: Any]()) { $0[$1.key] = redact($1.value, key: $1.key) }
            }
            return value
        }
        return String(
            data: try JSONSerialization.data(withJSONObject: redact(object), options: [.prettyPrinted, .sortedKeys]),
            encoding: .utf8)!
    }
    private static func extras(_ profile: APIProfile, protected: Set<String>) throws -> [String: Any] {
        guard let data = profile.extraJSON.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw StudioError.invalid("高级参数需为 JSON 对象。") }
        guard Set(object.keys).isDisjoint(with: protected) else {
            throw StudioError.invalid("高级参数不能覆盖提示词、模型、身份参考或密钥；请使用对应的专用字段。")
        }
        return object
    }
    private static func modelSegment(_ model: String) throws -> String {
        guard !model.isEmpty, !model.contains("/"), !model.contains("?"), !model.contains("#") else {
            throw StudioError.invalid("请填写有效模型 ID。")
        }
        return model
    }
    public static func text(profile p: APIProfile, token: String, prompt: String, images: [ReferenceImage] = []) throws
        -> PreparedRequest
    {
        guard p.kind.isText, !p.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw StudioError.invalid("请配置文本模型 ID。")
        }
        let extra = try extras(
            p, protected: ["model", "messages", "contents", "system", "stream", "api_key", "input", "instructions"])
        switch p.kind {
        case .chat:
            var payload: [String: Any] = [
                "model": p.model,
                "messages": [
                    [
                        "role": "user",
                        "content": images.isEmpty
                            ? prompt as Any
                            : ([["type": "text", "text": prompt]]
                                + images.map { ["type": "image_url", "image_url": ["url": $0.dataURL]] }),
                    ]
                ], "stream": false,
            ]
            guard ["max_tokens", "max_completion_tokens"].contains(p.textTokenField) else {
                throw StudioError.invalid("Chat 输出上限字段无效。")
            }
            payload[p.textTokenField] = p.textMaxTokens
            if let temp = p.temperature { payload["temperature"] = temp }
            payload.merge(extra) { _, n in n }
            return try jsonRequest(p, suffix: "chat/completions", payload: payload, token: token)
        case .responses:
            var content: [[String: Any]] = [["type": "input_text", "text": prompt]]
            content += images.map { ["type": "input_image", "image_url": $0.dataURL] }
            var payload: [String: Any] = [
                "model": p.model, "input": [["role": "user", "content": content]], "max_output_tokens": p.textMaxTokens,
                "stream": false, "store": false,
            ]
            if let temp = p.temperature { payload["temperature"] = temp }
            payload.merge(extra) { _, n in n }
            return try jsonRequest(p, suffix: "responses", payload: payload, token: token)
        case .anthropic:
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            content += images.map {
                [
                    "type": "image",
                    "source": ["type": "base64", "media_type": $0.mime, "data": $0.data.base64EncodedString()],
                ]
            }
            var payload: [String: Any] = [
                "model": p.model, "max_tokens": p.textMaxTokens, "messages": [["role": "user", "content": content]],
            ]
            if let temp = p.temperature { payload["temperature"] = temp }
            payload.merge(extra) { _, n in n }
            return try jsonRequest(p, suffix: "messages", payload: payload, token: token)
        case .geminiText:
            var parts: [[String: Any]] = [["text": prompt]]
            parts += images.map { ["inlineData": ["mimeType": $0.mime, "data": $0.data.base64EncodedString()]] }
            var config: [String: Any] = ["maxOutputTokens": p.textMaxTokens]
            if let temp = p.temperature { config["temperature"] = temp }
            var payload: [String: Any] = ["contents": [["role": "user", "parts": parts]], "generationConfig": config]
            payload.merge(extra) { _, n in n }
            return try jsonRequest(
                p, suffix: "models/\(try modelSegment(p.model)):generateContent", payload: payload, token: token)
        default: throw StudioError.invalid("此配置不是文本接口。")
        }
    }
    public static func image(profile p: APIProfile, token: String, prompt: ComposedPrompt, references: [ReferenceImage])
        throws -> PreparedRequest
    {
        guard !p.kind.isText, !p.model.isEmpty else { throw StudioError.invalid("请填写生图模型 ID。") }
        switch p.kind {
        case .novelAI:
            guard p.width >= 64, p.height >= 64, p.width <= 2048, p.height <= 2048, p.width % 64 == 0,
                p.height % 64 == 0, (1...50).contains(p.steps), prompt.characters.count <= 6
            else { throw StudioError.invalid("NAI 宽高需为64倍数，步数1—50；本适配器每格最多6个独立角色。") }
            var params: [String: Any] = [
                "params_version": 3, "width": p.width, "height": p.height, "scale": p.guidance,
                "seed": p.seed ?? UInt32.random(in: 0...UInt32.max), "steps": p.steps, "sampler": p.sampler,
                "noise_schedule": p.noiseSchedule, "n_samples": 1, "negative_prompt": prompt.negative,
                "qualityToggle": false, "ucPreset": 0, "legacy": false, "legacy_v3_extend": false, "sm": false,
                "sm_dyn": false, "uncond_scale": 1, "dynamic_thresholding": false, "prefer_brownian": true,
                "deliberate_euler_ancestral_bug": false, "skip_cfg_above_sigma": NSNull(),
                "reference_image_multiple": [], "reference_information_extracted_multiple": [],
                "reference_strength_multiple": [],
            ]
            if p.model.contains("diffusion-4") || p.model.contains("diffusion-5") {
                let charCaptions = prompt.characters.map {
                    ["char_caption": $0.prompt, "centers": [["x": $0.x, "y": $0.y]]] as [String: Any]
                }
                let negatives = prompt.characters.map {
                    ["char_caption": $0.negative, "centers": [["x": $0.x, "y": $0.y]]] as [String: Any]
                }
                params["use_coords"] = true
                params["characterPrompts"] = prompt.characters.map {
                    ["prompt": $0.prompt, "uc": $0.negative, "center": ["x": $0.x, "y": $0.y], "enabled": true]
                        as [String: Any]
                }
                params["v4_prompt"] = [
                    "caption": ["base_caption": prompt.naiBase, "char_captions": charCaptions], "use_coords": true,
                    "use_order": true,
                ]
                params["v4_negative_prompt"] = [
                    "caption": ["base_caption": prompt.negative, "char_captions": negatives], "legacy_uc": false,
                ]
            } else if !prompt.characters.isEmpty {
                throw StudioError.invalid("独立角色提示词需要 NAI V4 系列或兼容模型。")
            }
            var action = "generate"
            if p.referenceMode == .precise && !references.isEmpty {
                guard p.model.contains("diffusion-4-5"), references.count == 1, prompt.characters.count <= 1 else {
                    throw StudioError.invalid("本适配器精确参考仅用于 V4.5 单人物。多人叠加参考可能混脸，请改用独立角色提示词或其他多图平台。")
                }
                params["director_reference_images"] = references.map { $0.data.base64EncodedString() }
                params["director_reference_information_extracted"] = [1.0]
                params["director_reference_strength_values"] = [p.referenceStrength]
                params["director_reference_secondary_strength_values"] = [p.referenceFidelity]
                params["director_reference_descriptions"] = [
                    ["caption": ["base_caption": "character", "char_captions": []], "legacy_uc": false]
                ]
            } else if p.referenceMode == .imageToImage && !references.isEmpty {
                guard references.count == 1, prompt.characters.count <= 1 else {
                    throw StudioError.invalid("NAI 图生图仅使用单人物参考，避免多人混合。")
                }
                action = "img2img"
                params["image"] = references[0].data.base64EncodedString()
                params["strength"] = p.referenceStrength
                params["noise"] = 0
                params["extra_noise_seed"] = p.seed ?? 1
            }
            params.merge(
                try extras(
                    p,
                    protected: [
                        "input", "model", "prompt", "negative_prompt", "v4_prompt", "v4_negative_prompt",
                        "characterPrompts", "director_reference_images", "image", "n_samples", "api_key",
                    ])
            ) { _, n in n }
            return try jsonRequest(
                p, suffix: "ai/generate-image",
                payload: ["input": prompt.naiBase, "model": p.model, "action": action, "parameters": params],
                token: token)
        case .openAIImage:
            var payload: [String: Any] = [
                "model": p.model, "prompt": prompt.natural, "n": 1, "size": "\(p.width)x\(p.height)",
            ]
            let extra = try extras(p, protected: ["model", "prompt", "image", "images", "n", "api_key"])
            payload.merge(extra) { _, n in n }
            if references.isEmpty {
                return try jsonRequest(p, suffix: "images/generations", payload: payload, token: token)
            }
            let boundary = "Moxu-" + UUID().uuidString
            var data = Data()
            func add(_ s: String) { data.append(Data(s.utf8)) }
            for key in payload.keys.sorted() {
                let value = payload[key]!
                let s: String
                if let v = value as? String {
                    s = v
                } else if JSONSerialization.isValidJSONObject(value) {
                    s = String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
                } else {
                    s = String(describing: value)
                }
                add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(s)\r\n")
            }
            for (i, ref) in references.enumerated() {
                add(
                    "--\(boundary)\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"reference-\(i).\(ref.mime == "image/jpeg" ? "jpg" : "png")\"\r\nContent-Type: \(ref.mime)\r\n\r\n"
                )
                data.append(ref.data)
                add("\r\n")
            }
            add("--\(boundary)--\r\n")
            var headers = ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
            if !token.isEmpty { headers["Authorization"] = "Bearer " + token }
            var audit = payload
            audit["referenceImages"] = references.map { ["label": $0.label, "bytes": $0.data.count] }
            return PreparedRequest(
                url: try endpoint(p, suffix: "images/edits", override: p.editURL), headers: headers, body: data,
                redactedJSON: try auditJSON(audit))
        case .geminiImage:
            var parts: [[String: Any]] = [
                ["text": prompt.natural + "\n参考图顺序：" + references.map(\.label).joined(separator: "；")]
            ]
            parts += references.map { ["inlineData": ["mimeType": $0.mime, "data": $0.data.base64EncodedString()]] }
            var payload: [String: Any] = [
                "contents": [["role": "user", "parts": parts]],
                "generationConfig": ["responseModalities": ["TEXT", "IMAGE"]],
            ]
            payload.merge(try extras(p, protected: ["contents", "model", "api_key"])) { _, n in n }
            return try jsonRequest(
                p, suffix: "models/\(try modelSegment(p.model)):generateContent", payload: payload, token: token)
        default: throw StudioError.invalid("此配置不是生图接口。")
        }
    }
}
