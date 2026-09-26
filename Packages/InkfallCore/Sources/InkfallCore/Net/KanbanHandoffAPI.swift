import Foundation

/// 试做：Jev 判成「在叫助手」的那段话交给 Obsidian 看板（md-kanban）去做。不碰网络。
///
/// md-kanban 的 mobile control 在 `127.0.0.1:<port>` 上开着 `/api/open-issue`
/// （`src/mobile-control.ts`）：只把「起票」面板带着这段话打开，不建卡。
/// 作成先、模型由人在面板里选了再发 —— Jev 判错的代价只是多开一次面板。
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
        URL(string: "http://127.0.0.1:\(config.port)/api/open-issue")!
    }

    public static func headers(_ config: Config) -> [String: String] {
        ["Authorization": "Bearer \(config.token)", "Content-Type": "application/json"]
    }

    public static func body(text: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["input": text], options: [.sortedKeys])
    }

    /// `{"opened": true}` 才算开了。旧版 md-kanban 没有这个端点（404），调用方照常粘贴。
    public static func parseOpened(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["opened"] as? Bool == true
    }
}
