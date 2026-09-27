import Foundation
import InkfallCore

/// 历史记录落盘（试做，exp/interject）：助手模式下录的话不粘贴，记在这里。
///
/// 文件沿用减法前的 `history.json`（同一个目录、同一套字段），已有的旧记录原样保留。
@MainActor
final class HistoryStore {

    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/app.inkfall.native/history.json")

    private(set) var entries: [HistoryEntry]

    init() {
        entries = (try? Data(contentsOf: Self.url))
            .flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
    }

    func append(_ entry: HistoryEntry) {
        entries = HistoryEntry.appending(entry, to: entries)
        save()
    }

    /// 临时文件 + 替换。半截文件比没有文件更糟 —— 下次启动会连旧记录一起读不出来。
    private func save() {
        let directory = Self.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        let tmp = directory.appendingPathComponent("history.json.tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(Self.url, withItemAt: tmp)
        } catch {
            try? data.write(to: Self.url, options: .atomic)
            Log.write("history: 写入失败 \(error)")
        }
    }
}
