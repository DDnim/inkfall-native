import XCTest
@testable import InkfallCore

final class HistoryTests: XCTestCase {

    /// 本机真实的 history.json（减法前 / Tauri 版写的）必须读得进来，且写回不丢字段。
    func testDecodesExistingFileAndKeepsLegacyFields() throws {
        let json = #"""
        [{"createdAtMs": 1789222313252, "finalText": "音量。", "id": "20D27CE4", "postProcessingEnabled": true,
          "sourceText": "音量", "speakerNames": {}, "title": "2026-09-12 23:11", "transcriptionMode": "groq",
          "linkedNoteID": "ABC"},
         {"id": "X", "sourceText": "只有原文", "transcriptionMode": "groqProxy"}]
        """#
        let entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].displayText, "音量。")
        XCTAssertEqual(entries[0].transcriptionMode, .groq)
        XCTAssertEqual(entries[1].displayText, "只有原文")
        XCTAssertEqual(entries[1].transcriptionMode, .local)  // 认不出的旧模式不让整条丢掉
        XCTAssertFalse(entries[1].title.isEmpty)
        let again = try JSONDecoder().decode([HistoryEntry].self, from: JSONEncoder().encode(entries))
        XCTAssertEqual(again[0].linkedNoteID, "ABC")
    }

    func testAppendingPutsNewestFirstAndCaps() {
        let make = { (text: String) in
            HistoryEntry(sourceText: text, finalText: text, transcriptionMode: .groq,
                         postProcessingEnabled: false, postProcessingPreset: nil)
        }
        var entries: [HistoryEntry] = []
        for text in ["a", "b", "c"] { entries = HistoryEntry.appending(make(text), to: entries, limit: 2) }
        XCTAssertEqual(entries.map(\.sourceText), ["c", "b"])
    }
}
