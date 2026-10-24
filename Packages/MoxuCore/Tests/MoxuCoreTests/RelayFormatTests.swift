import XCTest

@testable import MoxuCore

private let relayPNG = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jTlcAAAAASUVORK5CYII=")!

private func relayObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func relayProfile(_ kind: APIKind = .openAIImage) -> APIProfile {
    var profile = APIProfile()
    profile.kind = kind
    profile.baseURL = "https://relay.example.test/v1/images/generations"
    profile.model = "nai-diffusion-4-5-full"
    profile.seed = 1234
    return profile
}

private func relayArtist() -> ArtistPreset {
    var artist = ArtistPreset()
    artist.positive = "  1.4::artist:one::, {{artist:two}}\n[artist:three]  "
    artist.negative = "  bad hands, {{blur}}\n0.8::watermark::  "
    artist.character = "  {fine linework}, 1.2::details::\n "
    artist.background = "  fog, [detailed background]\n "
    artist.imageRequestFormat = .novelAI
    return artist
}

private func relayScene() -> (Project, ComicPanel) {
    let left = CharacterCard(
        name: "林舟", stage: "成年", identity: ["hair": "黑发"], naiIdentity: "1boy, black hair",
        costumes: [Costume(naiLayers: ["top": "blue shirt"])])
    let right = CharacterCard(
        name: "苏禾", stage: "成年", identity: ["hair": "银发"], naiIdentity: "1girl, silver hair",
        costumes: [Costume(naiLayers: ["top": "red dress"])])
    var project = Project(title: "中转格式测试", chapters: [])
    project.characters = [left, right]
    let cast = [left, right].enumerated().map { index, card in
        PanelCast(
            characterID: card.id, costumeKey: "daily-01", pose: "站立", expression: "平静",
            position: index == 0 ? "左" : "右", visible: "全身", naiPose: "standing", layerStates: [:])
    }
    let panel = ComicPanel(
        id: "P0001", units: ["U00001"], scene: "S1", setting: "书店", action: "林舟与苏禾交谈",
        naiScene: "2people, bookstore", cast: cast)
    return (project, panel)
}

final class RelayFormatTests: XCTestCase {
    func testLegacyArtistAndSettingsDecodeWithoutNewFields() throws {
        let legacy = Data(
            #"{"id":"7B267122-23DD-4D7A-A9EA-712BDA75B06A","name":"旧画师","positive":"  {{artist:a}}\n ","negative":"bad hands","character":"linework","background":"fog","guidance":"保持原串","placement":"beforeFacts","revision":3}"#
                .utf8)
        let artist = try Codec.decode(ArtistPreset.self, legacy)
        XCTAssertNil(artist.imageRequestFormat)
        XCTAssertEqual(artist.positive, "  {{artist:a}}\n ")
        XCTAssertNil(try relayObject(Codec.encode(artist))["imageRequestFormat"])
        XCTAssertEqual(try Codec.decode(ArtistPreset.self, Codec.encode(artist)), artist)

        let profile = relayProfile()
        XCTAssertNil(try relayObject(Codec.encode(profile))["imageEndpointOverride"])
        var settings = AppSettings()
        settings.artists = [artist]
        settings.profiles = [profile]
        let restored = try Codec.decode(AppSettings.self, Codec.encode(settings))
        XCTAssertEqual(restored, settings)
        XCTAssertNil(restored.profiles[0].imageEndpointOverride)

        var selected = artist
        selected.imageRequestFormat = .novelAI
        XCTAssertEqual(try Codec.decode(ArtistPreset.self, Codec.encode(selected)), selected)
        selected.imageRequestFormat = .connection
        XCTAssertEqual(try Codec.decode(ArtistPreset.self, Codec.encode(selected)), selected)
    }

    func testOpenAIFullEndpointUsesNAIBodyHeadersAndIndependentCharacters() throws {
        let (project, panel) = relayScene()
        let artist = relayArtist()
        var original = relayProfile()
        original.width = 832
        original.height = 1216
        original.steps = 36
        original.guidance = 7.5
        original.sampler = "k_dpmpp_2m"
        original.noiseSchedule = "native"
        original.extraJSON = #"{"sm":true,"custom_value":"  keep\n spaces  "}"#
        let effective = try RequestBuilder.imageProfile(profile: original, artist: artist)
        var expected = original
        expected.kind = .novelAI
        expected.imageEndpointOverride = original.baseURL
        XCTAssertEqual(effective, expected)
        XCTAssertEqual(original.kind, .openAIImage)
        XCTAssertNil(original.imageEndpointOverride)
        XCTAssertEqual(try RequestBuilder.imageProfile(profile: effective, artist: artist), effective)

        var prompt = try PromptComposer.compose(panel: panel, project: project, artist: artist, profile: original)
        prompt.characters[0].negative = "bad left face"
        prompt.characters[1].negative = "bad right face"
        let request = try RequestBuilder.image(profile: effective, token: "test-secret", prompt: prompt, references: [])
        XCTAssertEqual(request.url.absoluteString, original.baseURL)
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["Authorization"], "Bearer test-secret")
        XCTAssertNil(request.headers["x-goog-api-key"])
        let body = try relayObject(request.body)
        XCTAssertEqual(Set(body.keys), ["input", "model", "action", "parameters"])
        XCTAssertEqual(body["input"] as? String, prompt.naiBase)
        XCTAssertTrue(prompt.naiBase.contains(artist.positive))
        XCTAssertTrue(prompt.naiBase.contains(artist.background))
        XCTAssertEqual(body["model"] as? String, original.model)
        XCTAssertEqual(body["action"] as? String, "generate")
        let params = try XCTUnwrap(body["parameters"] as? [String: Any])
        XCTAssertEqual(params["negative_prompt"] as? String, artist.negative)
        XCTAssertEqual(params["width"] as? Int, 832)
        XCTAssertEqual(params["height"] as? Int, 1216)
        XCTAssertEqual(params["steps"] as? Int, 36)
        XCTAssertEqual(params["scale"] as? Double, 7.5)
        XCTAssertEqual(params["seed"] as? Int, 1234)
        XCTAssertEqual(params["sampler"] as? String, original.sampler)
        XCTAssertEqual(params["noise_schedule"] as? String, original.noiseSchedule)
        XCTAssertEqual(params["custom_value"] as? String, "  keep\n spaces  ")
        XCTAssertEqual(params["sm"] as? Bool, true)
        let characters = try XCTUnwrap(params["characterPrompts"] as? [[String: Any]])
        XCTAssertEqual(characters.count, 2)
        for index in characters.indices {
            XCTAssertEqual(characters[index]["prompt"] as? String, prompt.characters[index].prompt)
            XCTAssertTrue(prompt.characters[index].prompt.contains(artist.character))
            XCTAssertEqual(characters[index]["uc"] as? String, prompt.characters[index].negative)
        }
        XCTAssertTrue(prompt.characters[0].prompt.contains("black hair"))
        XCTAssertFalse(prompt.characters[0].prompt.contains("silver hair"))
        XCTAssertTrue(prompt.characters[1].prompt.contains("silver hair"))
        let v4 = try XCTUnwrap(params["v4_prompt"] as? [String: Any])
        let caption = try XCTUnwrap(v4["caption"] as? [String: Any])
        XCTAssertEqual(caption["base_caption"] as? String, prompt.naiBase)
        XCTAssertEqual((caption["char_captions"] as? [[String: Any]])?.count, 2)
        let negative = try XCTUnwrap(params["v4_negative_prompt"] as? [String: Any])
        let negativeCaption = try XCTUnwrap(negative["caption"] as? [String: Any])
        XCTAssertEqual(negativeCaption["base_caption"] as? String, artist.negative)
        XCTAssertEqual(
            (negativeCaption["char_captions"] as? [[String: Any]])?.compactMap { $0["char_caption"] as? String },
            ["bad left face", "bad right face"])
        XCTAssertFalse(request.redactedJSON.contains("test-secret"))
    }

    func testExplicitImageEndpointsRemainExactForEitherOriginalKind() throws {
        let prompt = ComposedPrompt(natural: "scene", naiBase: "bookstore", negative: "", characters: [], fingerprint: "a")
        for kind in [APIKind.openAIImage, .novelAI] {
            for suffix in ["images/generations", "images/edits", "ai/generate-image"] {
                for trailingSlash in ["", "/"] {
                    var original = relayProfile(kind)
                    original.baseURL = "https://relay.example.test/custom/v1/" + suffix + trailingSlash
                    let effective = try RequestBuilder.imageProfile(profile: original, artist: relayArtist())
                    let request = try RequestBuilder.image(profile: effective, token: "", prompt: prompt, references: [])
                    XCTAssertEqual(request.url.absoluteString, original.baseURL)
                    XCTAssertEqual(try RequestBuilder.imageProfile(profile: effective, artist: relayArtist()), effective)
                }
            }
        }
    }

    func testRootEndpointUsesOriginalConnectionKindAndResolutionIsIdempotent() throws {
        for kind in [APIKind.openAIImage, .novelAI] {
            for base in ["https://relay.example.test", "https://relay.example.test/proxy/v1/"] {
                var original = relayProfile(kind)
                original.baseURL = base
                original.editURL = "https://relay.example.test/unrelated-edit"
                let expected = try RequestBuilder.endpoint(
                    original, suffix: kind == .openAIImage ? "images/generations" : "ai/generate-image")
                let effective = try RequestBuilder.imageProfile(profile: original, artist: relayArtist())
                XCTAssertEqual(effective.imageEndpointOverride, expected.absoluteString)
                XCTAssertEqual(try RequestBuilder.imageProfile(profile: effective, artist: relayArtist()), effective)
                XCTAssertEqual(effective.editURL, original.editURL)
            }
        }
    }

    func testDefaultAndConnectionFormatsKeepOpenAIRequests() throws {
        let (project, panel) = relayScene()
        let original = relayProfile()
        for format in [nil, ArtistImageRequestFormat.connection] {
            var artist = relayArtist()
            artist.imageRequestFormat = format
            let effective = try RequestBuilder.imageProfile(profile: original, artist: artist)
            XCTAssertEqual(effective, original)
            let prompt = try PromptComposer.compose(panel: panel, project: project, artist: artist, profile: original)
            let request = try RequestBuilder.image(profile: effective, token: "token", prompt: prompt, references: [])
            let body = try relayObject(request.body)
            XCTAssertEqual(request.url.absoluteString, original.baseURL)
            XCTAssertEqual(body["prompt"] as? String, prompt.natural)
            XCTAssertNil(body["input"])
            XCTAssertNil(body["parameters"])
        }
    }

    func testHTTPAndInlineSecretProtectionAppliesToOriginalAndResolvedURLs() throws {
        var profile = relayProfile()
        let artist = relayArtist()
        for bad in [
            "file:///tmp/image", "https://user:secret@relay.example.test/v1/images/generations",
            "https://relay.example.test/v1/images/generations?key=secret",
            "https://relay.example.test/v1/images/generations#secret",
            "http://192.168.1.2:8000/v1/images/generations",
        ] {
            profile.baseURL = bad
            XCTAssertThrowsError(try RequestBuilder.imageProfile(profile: profile, artist: artist))
            profile.baseURL = "https://relay.example.test/v1"
            profile.imageEndpointOverride = bad
            XCTAssertThrowsError(try RequestBuilder.imageProfile(profile: profile, artist: artist))
            profile.imageEndpointOverride = nil
        }
        profile.baseURL = "http://192.168.1.2:8000/v1"
        profile.allowHTTP = true
        let effective = try RequestBuilder.imageProfile(profile: profile, artist: artist)
        XCTAssertEqual(effective.imageEndpointOverride, "http://192.168.1.2:8000/v1/images/generations")
        var forbidden = effective
        forbidden.allowHTTP = false
        XCTAssertThrowsError(try RequestBuilder.imageProfile(profile: forbidden, artist: artist))
        let prompt = ComposedPrompt(natural: "scene", naiBase: "bookstore", negative: "", characters: [], fingerprint: "a")
        XCTAssertThrowsError(try RequestBuilder.image(profile: forbidden, token: "", prompt: prompt, references: []))
    }

    func testUnsupportedConnectionsRejectNAIFormatClearly() throws {
        for kind in APIKind.allCases where kind != .novelAI && kind != .openAIImage {
            let profile = relayProfile(kind)
            XCTAssertThrowsError(try RequestBuilder.imageProfile(profile: profile, artist: relayArtist())) { error in
                XCTAssertTrue(error.localizedDescription.contains("NAI 请求格式"))
            }
        }
    }

    func testFormatChangesFingerprintWithoutChangingAnyArtistStrings() throws {
        let (project, panel) = relayScene()
        let profile = relayProfile()
        var artist = relayArtist()
        artist.imageRequestFormat = nil
        let original = artist
        let follow = try PromptComposer.compose(panel: panel, project: project, artist: artist, profile: profile)
        let references = project.characters.map { "\($0.id)/\($0.revision)/\($0.referenceFile ?? "")" }.joined(separator: "|")
        let oldSignature = StableID.digest(
            follow.natural + follow.naiBase + artist.negative + follow.characters.map(\.prompt).joined() + references
                + String(data: try Codec.encode(profile), encoding: .utf8)!)
        XCTAssertEqual(follow.fingerprint, oldSignature)
        artist.imageRequestFormat = .connection
        let connection = try PromptComposer.compose(panel: panel, project: project, artist: artist, profile: profile)
        XCTAssertEqual(follow.fingerprint, connection.fingerprint)
        artist.imageRequestFormat = .novelAI
        let nai = try PromptComposer.compose(panel: panel, project: project, artist: artist, profile: profile)
        XCTAssertNotEqual(follow.fingerprint, nai.fingerprint)
        XCTAssertEqual(nai.natural, follow.natural)
        XCTAssertEqual(nai.naiBase, follow.naiBase)
        XCTAssertEqual(nai.negative, follow.negative)
        XCTAssertEqual(nai.characters, follow.characters)
        XCTAssertEqual(artist.positive, original.positive)
        XCTAssertEqual(artist.negative, original.negative)
        XCTAssertEqual(artist.character, original.character)
        XCTAssertEqual(artist.background, original.background)
        let resolved = try RequestBuilder.imageProfile(profile: profile, artist: artist)
        XCTAssertEqual(
            nai.fingerprint,
            try PromptComposer.compose(panel: panel, project: project, artist: artist, profile: resolved).fingerprint)
    }

    func testNAIRelayResponseSupportsZIPRawImageAndOpenAIBase64() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RelayFormat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("image.png")
        let archive = folder.appendingPathComponent("response.zip")
        try relayPNG.write(to: image)
        try ZIPArchive.write(files: ["image_0.png": image], to: archive)
        let b64JSON = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": relayPNG.base64EncodedString()]]])
        let dataURLJSON = try JSONSerialization.data(withJSONObject: [
            "data": [["url": "data:image/png;base64," + relayPNG.base64EncodedString()]]
        ])
        let replies = [try Data(contentsOf: archive), relayPNG, b64JSON, dataURLJSON]
        let transport = MockTransport(replies.map { HTTPResult(data: $0) })
        let client = ProviderClient(transport: transport)
        let profile = try RequestBuilder.imageProfile(profile: relayProfile(), artist: relayArtist())
        let prompt = ComposedPrompt(natural: "scene", naiBase: "bookstore", negative: "", characters: [], fingerprint: "a")
        let request = try RequestBuilder.image(profile: profile, token: "secret", prompt: prompt, references: [])
        for _ in replies {
            let result = try await client.generate(request, profile: profile)
            XCTAssertEqual(result, relayPNG)
        }
        let calls = await transport.recorded()
        XCTAssertEqual(calls.count, replies.count)
        XCTAssertTrue(calls.allSatisfy { $0.url.absoluteString == relayProfile().baseURL && $0.method == "POST" })
        for call in calls { XCTAssertNotNil(try relayObject(call.body)["parameters"]) }
    }

    func testNAIRelayOpenAIImageURLDownloadDoesNotForwardCredentials() async throws {
        let transport = MockTransport([
            HTTPResult(data: Data(#"{"data":[{"url":"https://cdn.example.test/relay-image.png"}]}"#.utf8)),
            HTTPResult(data: relayPNG),
        ])
        let client = ProviderClient(transport: transport)
        let profile = try RequestBuilder.imageProfile(profile: relayProfile(), artist: relayArtist())
        let prompt = ComposedPrompt(natural: "scene", naiBase: "bookstore", negative: "", characters: [], fingerprint: "a")
        let request = try RequestBuilder.image(profile: profile, token: "secret", prompt: prompt, references: [])
        let result = try await client.generate(request, profile: profile)
        XCTAssertEqual(result, relayPNG)
        let calls = await transport.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].url.absoluteString, relayProfile().baseURL)
        XCTAssertEqual(calls[0].headers["Authorization"], "Bearer secret")
        XCTAssertEqual(calls[1].url.absoluteString, "https://cdn.example.test/relay-image.png")
        XCTAssertEqual(calls[1].method, "GET")
        XCTAssertTrue(calls[1].headers.isEmpty)
    }
}
