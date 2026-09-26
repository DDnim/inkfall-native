import Foundation

/// 试做：Jev 判成「在叫助手」的那段话交给 Obsidian 看板（md-kanban）去做。不碰网络。
///
/// md-kanban 的 mobile control 在 `127.0.0.1:<port>` 上开着 `/api/create`
/// （`src/mobile-control.ts`）：起一张卡，`mode: "work-only"` 表示不起票、直接派发去做。
/// 端口与 token 在 vault 的 `.obsidian/plugins/md-kanban/data.json` 的 `mobileControl` 里。
public enum KanbanHandoffAPI {

    public struct Config: Equatable, Sendable {
        public let port: Int
        public let token: String
    }

    /// 从 md-kanban 的 data.json 里读 `mobileControl`。没开、没 token 就是 nil。
    public static func config(fromPluginData data: Data) -> Config? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let control = root["mobileControl"] as? [String: Any],
              control["enabled"] as? Bool == true,
              let port = (control["port"] as? NSNumber)?.intValue, (1024...65535).contains(port),
              let token = control["token"] as? String, !token.isEmpty
        else { return nil }
        return Config(port: port, token: token)
    }

    public static func endpoint(_ config: Config) -> URL {
        URL(string: "http://127.0.0.1:\(config.port)/api/create")!
    }

    public static func headers(_ config: Config) -> [String: String] {
        ["Authorization": "Bearer \(config.token)", "Content-Type": "application/json"]
    }

    /// `project: ""` 是起票面板的「ローカル」（全体）。
    public static func body(text: String, project: String = "") -> Data? {
        let payload: [String: Any] = ["input": text, "project": project, "mode": "work-only"]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// `{"path": "Task/xxx.md"}` → 卡片名（不带目录与 .md）
    public static func parseCardName(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = root["path"] as? String, !path.isEmpty
        else { throw TextGenerationAPI.Failure.malformedResponse }
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }
}
