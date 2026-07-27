import Foundation
import InkfallCore

/// 笔记落盘。
///
/// 文件名沿用 Tauri 版的 `history.json` / `note_session.json`
/// （spec/03 §1）—— 名字叫 history 是向后兼容，产品上它已经是「笔记」。
@MainActor
@Observable
final class NoteStore {

    /// 最多留 100 条。超出的从最旧的开始丢。
    private static let limit = 100

    private(set) var notes: [HistoryEntry] = []

    private static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/app.inkfall.native")

    init() {
        notes = Self.load([HistoryEntry].self, from: "history.json") ?? []
    }

    // MARK: - 笔记

    /// 新建或就地更新。落笔会话录音期间会反复调用同一个 id。
    func upsert(_ entry: HistoryEntry) {
        if let index = notes.firstIndex(where: { $0.id == entry.id }) {
            notes[index] = entry
        } else {
            notes.insert(entry, at: 0)
            if notes.count > Self.limit { notes.removeLast(notes.count - Self.limit) }
        }
        save()
    }

    func remove(id: String) {
        notes.removeAll { $0.id == id }
        save()
    }

    func note(id: String) -> HistoryEntry? { notes.first { $0.id == id } }

    private func save() {
        Self.write(notes, to: "history.json")
    }

    // MARK: - 会话

    func loadSession() -> NoteSession? {
        Self.load(NoteSession.self, from: "note_session.json")
    }

    func saveSession(_ session: NoteSession?) {
        guard let session else {
            try? FileManager.default.removeItem(
                at: Self.directory.appendingPathComponent("note_session.json"))
            return
        }
        Self.write(session, to: "note_session.json")
    }

    // MARK: - 原子读写

    private static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// 临时文件 + 替换。半截文件比没有文件更糟 —— 下次启动会连着旧数据一起丢。
    private static func write<T: Encodable>(_ value: T, to name: String) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        let target = directory.appendingPathComponent(name)
        let tmp = directory.appendingPathComponent(name + ".tmp")
        do {
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: target)
            }
        } catch {
            Log.write("note: 写入 \(name) 失败 \(error)")
        }
    }
}
