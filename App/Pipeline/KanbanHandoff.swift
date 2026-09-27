import AppKit
import InkfallCore

/// 试做：Jev 判成 call 的那段话送进 Obsidian 看板的「起票」面板（md-kanban 的 `/api/open-issue`），
/// 再把 Obsidian 叫到前台。建不建卡、发到哪由人决定。
///
/// 端口与 token 每次现读 vault 里 md-kanban 的 data.json（token 在 Obsidian 那边可能被换掉）。
/// vault 默认 `~/repos/Memo`，可用 `INKFALL_KANBAN_VAULT` 改。Obsidian 没开、没开 mobile
/// control、请求失败都回 false —— 调用方要照常粘贴，**文字不能丢**。
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

    /// 助手模式：后台建卡让 agent 去做（`/api/create`，不开面板、不叫 Obsidian 到前台）。
    /// 建好了回卡的路径，失败回 nil。
    func createCard(_ text: String) async -> String? {
        guard let data = try? Data(contentsOf: Self.pluginData),
              let config = KanbanHandoffAPI.config(fromPluginData: data),
              let body = KanbanHandoffAPI.createBody(text: text) else {
            Log.write("kanban: 没读到 mobileControl（\(Self.pluginData.path)）")
            return nil
        }
        var request = URLRequest(url: KanbanHandoffAPI.createEndpoint(config))
        request.httpMethod = "POST"
        request.httpBody = body
        for (field, value) in KanbanHandoffAPI.headers(config) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await Self.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let path = KanbanHandoffAPI.parseCreated(data) else {
                Log.write("kanban: 建卡 HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))")
                return nil
            }
            return path
        } catch {
            Log.write("kanban: 建卡失败 \(error.localizedDescription)")
            return nil
        }
    }

    /// 面板开了才回 true。
    func send(_ text: String) async -> Bool {
        guard let data = try? Data(contentsOf: Self.pluginData),
              let config = KanbanHandoffAPI.config(fromPluginData: data) else {
            Log.write("kanban: 没读到 mobileControl（\(Self.pluginData.path)）")
            return false
        }
        guard let body = KanbanHandoffAPI.body(text: text) else { return false }
        var request = URLRequest(url: KanbanHandoffAPI.endpoint(config))
        request.httpMethod = "POST"
        request.httpBody = body
        for (field, value) in KanbanHandoffAPI.headers(config) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await Self.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, KanbanHandoffAPI.parseOpened(data) else {
                Log.write("kanban: HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))")
                return false
            }
            await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian").first?.activate()
            }
            return true
        } catch {
            Log.write("kanban: 失败 \(error.localizedDescription)")
            return false
        }
    }
}
