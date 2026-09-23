import XCTest
@testable import InkfallCore

// 云端转写链路里不需要活的 App 环境的那一半：multipart 的每个字节、
// 三条路的端点与鉴权头、语言字段、响应解析。
//
// 真正发请求那一层在 App 里（`CloudTranscriber`），靠
// `--cloud-transcribe-test <wav>` 真机验证。

final class MultipartFormTests: XCTestCase {

    /// 字节级：CRLF、边界、Content-Disposition 的写法都算行为 ——
    /// Groq 对这些很挑，一次「多了一个 \n」就是整场 400。
    func testByteExactLayout() {
        var form = MultipartForm(boundary: "InkfallBoundaryTEST")
        form.addField("model", "whisper-large-v3-turbo")
        form.addFile("file", filename: "take.wav", mimeType: "audio/wav", data: Data([0x52, 0x49, 0x46, 0x46]))
        let body = String(decoding: form.build(), as: UTF8.self)
        XCTAssertEqual(body,
            "--InkfallBoundaryTEST\r\n"
            + "Content-Disposition: form-data; name=\"model\"\r\n\r\n"
            + "whisper-large-v3-turbo\r\n"
            + "--InkfallBoundaryTEST\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"take.wav\"\r\n"
            + "Content-Type: audio/wav\r\n\r\n"
            + "RIFF\r\n"
            + "--InkfallBoundaryTEST--\r\n")
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=InkfallBoundaryTEST")
    }

    func testDefaultBoundaryHasInkfallPrefix() {
        let form = MultipartForm()
        XCTAssertTrue(form.boundary.hasPrefix("InkfallBoundary"))
        XCTAssertGreaterThan(form.boundary.count, "InkfallBoundary".count)
    }

    func testFilenameSanitized() {
        XCTAssertEqual(MultipartForm.sanitizeFilename("  "), "inkfall-recording.wav")
        XCTAssertEqual(MultipartForm.sanitizeFilename("a/b\\c:d.wav"), "a_b_c_d.wav")
        XCTAssertEqual(MultipartForm.sanitizeFilename(" take.wav "), "take.wav")
    }
}

final class TranscriptionAPITests: XCTestCase {

    private let audio = RecordedAudio(filename: "take.wav", mimeType: "audio/wav",
                                      data: Data("RIFFxxxx".utf8), durationMs: 1_200)
    private var defaults: AppSettings { AppSettings() }

    // MARK: 端点与鉴权

    func testGroqRequestShape() throws {
        let prepared = try TranscriptionAPI.prepare(
            route: .groq(model: "whisper-large-v3-turbo", key: "gsk_abc"),
            audio: audio, language: "zh", boundary: "InkfallBoundaryTEST")
        XCTAssertEqual(prepared.url.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(prepared.headers["Authorization"], "Bearer gsk_abc")
        XCTAssertEqual(prepared.headers["Content-Type"], "multipart/form-data; boundary=InkfallBoundaryTEST")
        let body = String(decoding: prepared.body, as: UTF8.self)
        XCTAssertEqual(body,
            "--InkfallBoundaryTEST\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n"
            + "--InkfallBoundaryTEST\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nzh\r\n"
            + "--InkfallBoundaryTEST\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\nverbose_json\r\n"
            + "--InkfallBoundaryTEST\r\nContent-Disposition: form-data; name=\"file\"; filename=\"take.wav\"\r\n"
            + "Content-Type: audio/wav\r\n\r\nRIFFxxxx\r\n"
            + "--InkfallBoundaryTEST--\r\n")
    }

    func testOpenAIEndpointAndAutoLanguageOmitsField() throws {
        let prepared = try TranscriptionAPI.prepare(
            route: .openai(model: "gpt-4o-mini-transcribe", key: "sk-1"),
            audio: audio, language: nil, boundary: "B")
        XCTAssertEqual(prepared.url.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(prepared.headers["Authorization"], "Bearer sk-1")
        let body = String(decoding: prepared.body, as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"language\""))
        // gpt-4o-*-transcribe 不支持 verbose_json，传了会 400。
        XCTAssertFalse(body.contains("verbose_json"))
    }

    func testOpenAIWhisper1RequestsVerboseJSON() throws {
        let prepared = try TranscriptionAPI.prepare(
            route: .openai(model: "whisper-1", key: "sk-1"), audio: audio, language: nil, boundary: "B")
        XCTAssertTrue(String(decoding: prepared.body, as: UTF8.self).contains("verbose_json"))
    }

    func testVocabularyBecomesPrompt() throws {
        let direct = try TranscriptionAPI.prepare(
            route: .groq(model: "whisper-large-v3", key: "k"), audio: audio, language: nil,
            vocabulary: [" 落音", "Inkfall", "落音", ""], boundary: "B")
        let body = String(decoding: direct.body, as: UTF8.self)
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n落音, Inkfall\r\n"))
    }

    func testGeminiRequestInlinesAudioAsBase64() throws {
        let policy = TranscriptionLanguagePolicy(mode: .auto, fixed: .zh, preferred: [])
        let instruction = TranscriptionAPI.geminiLanguageInstruction(policy: policy, requested: "zh")
        let prepared = try TranscriptionAPI.prepare(
            route: .gemini(model: "gemini-3.1-flash-lite-preview", key: "g-1"),
            audio: audio, language: "zh", languageInstruction: instruction)
        XCTAssertEqual(prepared.url.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite-preview:generateContent")
        XCTAssertEqual(prepared.headers["x-goog-api-key"], "g-1")
        XCTAssertEqual(prepared.headers["Content-Type"], "application/json")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        let text = try XCTUnwrap(parts[0]["text"] as? String)
        XCTAssertTrue(text.hasPrefix(TranscriptionAPI.geminiPromptBase))
        XCTAssertTrue(text.hasSuffix("Transcribe in Chinese."))
        let inline = try XCTUnwrap(parts[1]["inline_data"] as? [String: Any])
        XCTAssertEqual(inline["mime_type"] as? String, "audio/wav")
        XCTAssertEqual(inline["data"] as? String, Data("RIFFxxxx".utf8).base64EncodedString())
        let config = try XCTUnwrap(object["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["temperature"] as? Double, 0.0)
    }

    func testGeminiLanguageInstructionFollowsPolicy() {
        let fixed = TranscriptionLanguagePolicy(mode: .fixed, fixed: .ja, preferred: [])
        XCTAssertEqual(TranscriptionAPI.geminiLanguageInstruction(policy: fixed, requested: nil),
                       "Transcribe in Japanese.")
        let preferred = TranscriptionLanguagePolicy(mode: .preferred, fixed: .zh, preferred: [.zh, .en])
        XCTAssertEqual(TranscriptionAPI.geminiLanguageInstruction(policy: preferred, requested: nil),
                       "Prefer these languages when the audio is ambiguous: Chinese, English.")
        let auto = TranscriptionLanguagePolicy(mode: .auto, fixed: .zh, preferred: [])
        XCTAssertEqual(TranscriptionAPI.geminiLanguageInstruction(policy: auto, requested: nil),
                       "Detect the spoken language automatically.")
        // 会话已锁定 → 点名，不管模式。
        XCTAssertEqual(TranscriptionAPI.geminiLanguageInstruction(policy: auto, requested: "en"),
                       "Transcribe in English.")
    }

    // MARK: 音频门槛

    func testEmptyAndOversizedAudioRejectedBeforeSending() {
        let empty = RecordedAudio(data: Data(), durationMs: 0)
        XCTAssertThrowsError(try TranscriptionAPI.prepare(
            route: .groq(model: "whisper-large-v3", key: "k"), audio: empty, language: nil)) {
            XCTAssertEqual($0 as? TranscriptionAPI.Failure, .noAudio)
        }
        let huge = RecordedAudio(data: Data(count: TranscriptionAPI.maxAudioBytes + 1), durationMs: 0)
        XCTAssertThrowsError(try TranscriptionAPI.prepare(
            route: .groq(model: "whisper-large-v3", key: "k"), audio: huge, language: nil)) {
            XCTAssertEqual($0 as? TranscriptionAPI.Failure, .audioTooLarge)
        }
    }

    // MARK: 解析

    func testParseVerboseJSONCarriesLanguage() throws {
        let data = Data(#"{"text":"  你好，世界 ","language":"Chinese","duration":1.2}"#.utf8)
        let parsed = try TranscriptionAPI.parse(route: .groq(model: "m", key: "k"), data: data)
        XCTAssertEqual(parsed, .init(text: "你好，世界", language: "Chinese"))
        XCTAssertEqual(TranscriptionLanguage.detected(parsed.language), .zh)
    }

    func testParsePlainJSONHasNoLanguage() throws {
        let data = Data(#"{"text":"hello"}"#.utf8)
        let parsed = try TranscriptionAPI.parse(route: .openai(model: "m", key: "k"), data: data)
        XCTAssertEqual(parsed, .init(text: "hello", language: nil))
    }

    func testParseAcceptsDetectedLanguageKey() throws {
        let data = Data(#"{"text":"こんにちは","detectedLanguage":"ja"}"#.utf8)
        let route = TranscriptionAPI.Route.groq(model: "m", key: "k")
        XCTAssertEqual(try TranscriptionAPI.parse(route: route, data: data).language, "ja")
    }

    func testParseEmptyAndMalformed() {
        let route = TranscriptionAPI.Route.groq(model: "whisper-large-v3", key: "k")
        XCTAssertThrowsError(try TranscriptionAPI.parse(route: route, data: Data(#"{"text":"  "}"#.utf8))) {
            XCTAssertEqual($0 as? TranscriptionAPI.Failure, .emptyTranscript("Groq whisper-large-v3"))
        }
        XCTAssertThrowsError(try TranscriptionAPI.parse(route: route, data: Data("nope".utf8))) {
            XCTAssertEqual($0 as? TranscriptionAPI.Failure, .malformedResponse)
        }
    }

    func testParseGemini() throws {
        let data = Data(#"{"candidates":[{"content":{"parts":[{"text":" 你好 "}]}}]}"#.utf8)
        let parsed = try TranscriptionAPI.parse(route: .gemini(model: "m", key: "k"), data: data)
        XCTAssertEqual(parsed, .init(text: "你好", language: nil))
        XCTAssertThrowsError(try TranscriptionAPI.parse(
            route: .gemini(model: "m", key: "k"),
            data: Data(#"{"candidates":[{"content":{"parts":[{"text":""}]}}]}"#.utf8))) {
            XCTAssertEqual($0 as? TranscriptionAPI.Failure, .emptyTranscript("Gemini m"))
        }
    }

    func testServerErrorMessageExtracted() {
        let gemini = Data(#"{"error":{"code":400,"message":" API key not valid. ","status":"INVALID_ARGUMENT"}}"#.utf8)
        XCTAssertEqual(TextGenerationAPI.errorMessage(in: gemini), "API key not valid.")
        // Gemini 的 code 是数字，不该被当成错误码字符串。
        XCTAssertEqual(TextGenerationAPI.errorCode(in: gemini), "")
        XCTAssertEqual(TextGenerationAPI.errorMessage(in: Data(#"{"error":"unauthorized"}"#.utf8)), "")
        XCTAssertEqual(TextGenerationAPI.errorMessage(in: Data("not json".utf8)), "")
    }

    // MARK: 模型白名单

    func testModelFallsBackToDefaultWhenNotWhitelisted() {
        var settings = defaults
        settings.selectedGroqModel = "whisper-large-v3"
        XCTAssertEqual(TranscriptionAPI.model(for: .groq, settings: settings), "whisper-large-v3")
        settings.selectedGroqModel = "made-up"
        XCTAssertEqual(TranscriptionAPI.model(for: .groq, settings: settings), "whisper-large-v3-turbo")
        settings.selectedOpenAiModel = "whisper-1"
        XCTAssertEqual(TranscriptionAPI.model(for: .openai, settings: settings), "whisper-1")
        settings.selectedOpenAiModel = "nope"
        XCTAssertEqual(TranscriptionAPI.model(for: .openai, settings: settings), "gpt-4o-mini-transcribe")
        settings.selectedGeminiModel = "nope"
        XCTAssertEqual(TranscriptionAPI.model(for: .gemini, settings: settings), "gemini-3.1-flash-lite-preview")
    }

    /// 降级只在网络/5xx；鉴权/配额必须浮出来（A15）。这条已有单测，这里只钉
    /// 「本地模型没下载就不能降级」这一半，因为转写的降级目标是**模型**而不是规则。
    func testTranscriptionFallbackNeedsLocalModel() {
        XCTAssertTrue(FallbackPolicy.shouldFallbackTranscription(
            autoLocalFallbackEnabled: true, kind: .network, localModelReady: true))
        XCTAssertFalse(FallbackPolicy.shouldFallbackTranscription(
            autoLocalFallbackEnabled: true, kind: .network, localModelReady: false))
        XCTAssertFalse(FallbackPolicy.shouldFallbackTranscription(
            autoLocalFallbackEnabled: true, kind: .auth, localModelReady: true))
        XCTAssertFalse(FallbackPolicy.shouldFallbackTranscription(
            autoLocalFallbackEnabled: false, kind: .serverError, localModelReady: true))
    }
}
