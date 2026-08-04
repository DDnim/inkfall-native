import XCTest
@testable import InkfallCore

// 全篇转译的两半纯逻辑：该拼哪些片段、怎么拼。
//
// 「跑一次分离」那一半要活的模型，在 App 里靠 `--full-transcribe-test` 验。

final class NoteAudioTests: XCTestCase {

    /// 一段 16 bit PCM 的假录音。`seconds` 决定 data 块大小。
    private func wav(seconds: Double, sampleRate: UInt32 = 16_000,
                     channels: UInt16 = 1, fill: UInt8 = 0x11) -> Data {
        let count = Int(Double(sampleRate) * Double(channels) * 2 * seconds)
        return WAV.encode(pcm: Data(repeating: fill, count: count),
                          sampleRate: sampleRate, channels: channels)
    }

    // MARK: - 该拼哪些

    /// 正文里仍存在的 `[audio](…)` 就是真相源 —— 用户删掉的语音条要跟着掉出去。
    func testReferencesInOrder() {
        let body = """
        第一段说了点什么
        [audio](voice-1700000000000.wav)
        第二段
        [audio](voice-1700000005000.wav)
        """
        XCTAssertEqual(NoteAudio.references(inMarkdown: body),
                       ["voice-1700000000000.wav", "voice-1700000005000.wav"])
    }

    /// ⚠️ 安全面：正文是用户可编辑的，`[audio](../../别人的东西)` 不能让它
    /// 读到笔记目录外面去。
    func testReferencesRejectPathsAndForeignNames() {
        let body = """
        [audio](../../etc/passwd)
        [audio](/tmp/voice-1.wav)
        [audio](sub/voice-1.wav)
        [audio](shot-abc.png)
        [audio]()
        ![截图](file:///x/shot.png)
        """
        XCTAssertTrue(NoteAudio.references(inMarkdown: body).isEmpty)
    }

    func testNoReferencesWhenBodyHasNone() {
        XCTAssertTrue(NoteAudio.references(inMarkdown: "就是一段普通正文。\n没有语音条。").isEmpty)
    }

    // MARK: - 怎么拼

    func testConcatenatesPCMAndReportsDuration() throws {
        let result = try XCTUnwrap(NoteAudio.concatenate([wav(seconds: 1.0), wav(seconds: 0.5)]))
        XCTAssertEqual(result.usedClips, 2)
        XCTAssertEqual(result.skippedClips, 0)
        XCTAssertEqual(result.durationMs, 1_500)

        // 拼出来的必须还是一个能解析的 WAV，而不是几个头粘在一起。
        let info = try XCTUnwrap(WAV.parse(result.data))
        XCTAssertEqual(info.sampleRate, 16_000)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.dataRange.count, 16_000 * 2 * 3 / 2)
    }

    /// ⚠️ 以第一段的格式为准，不一致的跳过。裸 PCM 硬拼上去只会得到变调的
    /// 噪声 —— 「换了个麦克风之后全篇转译出来全是乱码」就是这么来的。
    func testMismatchedFormatsSkippedNotBlended() throws {
        let result = try XCTUnwrap(NoteAudio.concatenate([
            wav(seconds: 1.0, sampleRate: 16_000, channels: 1),
            wav(seconds: 1.0, sampleRate: 48_000, channels: 1),   // 采样率不同
            wav(seconds: 1.0, sampleRate: 16_000, channels: 2),   // 声道数不同
            wav(seconds: 1.0, sampleRate: 16_000, channels: 1),
        ]))
        XCTAssertEqual(result.usedClips, 2)
        XCTAssertEqual(result.skippedClips, 2)
        XCTAssertEqual(result.durationMs, 2_000)
    }

    /// 坏文件不能让整篇转译失败 —— 跳过它，剩下的照拼。
    func testGarbageClipsSkipped() throws {
        let result = try XCTUnwrap(NoteAudio.concatenate([
            Data("这不是 WAV".utf8), wav(seconds: 1.0), Data(),
        ]))
        XCTAssertEqual(result.usedClips, 1)
        XCTAssertEqual(result.skippedClips, 2)
    }

    func testNothingUsableIsNil() {
        XCTAssertNil(NoteAudio.concatenate([]))
        XCTAssertNil(NoteAudio.concatenate([Data("坏的".utf8)]))
        // 只有头没有数据的 WAV 也算没内容。
        XCTAssertNil(NoteAudio.concatenate([WAV.encode(pcm: Data(), sampleRate: 16_000,
                                                       channels: 1)]))
    }

    // MARK: - 命名与标题

    /// 文件名按毫秒排序 = 按说话顺序。正文里没有 `[audio]` 标记时全靠它。
    func testClipNamesSortIntoSpeakingOrder() {
        let names = [NoteAudio.clipName(atMs: 1_700_000_010_000),
                     NoteAudio.clipName(atMs: 1_700_000_002_000),
                     NoteAudio.clipName(atMs: 1_700_000_001_000)]
        XCTAssertEqual(names.sorted(),
                       ["voice-1700000001000.wav", "voice-1700000002000.wav",
                        "voice-1700000010000.wav"])
        XCTAssertTrue(NoteAudio.isClipName("voice-1.wav"))
        XCTAssertFalse(NoteAudio.isClipName("shot-1.png"))
    }

    func testResultTitle() {
        XCTAssertEqual(NoteAudio.resultTitle(from: "周会"), "周会 · 全篇转译")
        XCTAssertEqual(NoteAudio.resultTitle(from: "  "), "全篇转译")
    }
}
