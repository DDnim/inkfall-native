import Foundation
import InkfallCore

/// 试做：Jev 判成 call 的那段话交给 Obsidian 看板（md-kanban 的 `/api/create`）。
///
/// 端口与 token 每次现读 vault 里 md-kanban 的 data.json（token 在 Obsidian 那边可能被换掉）。
/// vault 默认 `~/repos/Memo`，可用 `INKFALL_KANBAN_VAULT` 改。Obsidian 没开、没开 mobile
/// control、请求失败都回 nil —— 调用方要照常粘贴，**文字不能丢**。
final class KanbanHandoff: @unchecked Sendable {

    /// 本机回环，1.5 秒还不回就是 Obsidian 卡住或没开。
    static let timeout: TimeInterval = 1.5

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }()

    private static var pluginData: URL {
        let vault = ProcessInfo.processInfo.environment["INKFALL_KANBAN_VAULT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("repos/Memo")
        return vault.appendingPathComponent(".obsidian/plugins/md-kanban/data.json")
    }

    /// 成功回卡片名。
    func send(_ text: String) async -> String? {
        guard let data = try? Data(contentsOf: Self.pluginData),
              let config = KanbanHandoffAPI.config(fromPluginData: data) else {
            Log.write("kanban: 没读到 mobileControl（\(Self.pluginData.path)）")
            return nil
        }
        guard let body = KanbanHandoffAPI.body(text: text) else { return nil }
        var request = URLRequest(url: KanbanHandoffAPI.endpoint(config))
        request.httpMethod = "POST"
        request.httpBody = body
        for (field, value) in KanbanHandoffAPI.headers(config) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await Self.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                Log.write("kanban: HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))")
                return nil
            }
            return try KanbanHandoffAPI.parseCardName(data)
        } catch {
            Log.write("kanban: 失败 \(error.localizedDescription)")
            return nil
        }
    }
}
