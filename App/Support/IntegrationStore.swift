import Foundation
import InkfallCore

/// 本地集成 API 的凭据与 MCP 桥脚本（spec/03 §10、spec/04 §4）。
///
/// token 让任何本机进程（MCP 桥、curl）不用手工拷贝就能拿到访问权，
/// 同时把同一台机器上的**其他用户**挡在外面 —— 所以文件权限是 `0600`。
enum IntegrationStore {

    static let port: UInt16 = 48765

    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/app.inkfall.native")
    }

    static var tokenPath: URL { directory.appendingPathComponent("integration_token") }
    /// 注册给编码助手的路径**必须稳定**，所以脚本固定写在这里。
    static var mcpScriptPath: URL { directory.appendingPathComponent("inkfall-mcp.mjs") }

    /// 读一次就记住。文件 IO 在 HTTP 的热路径上，每条请求都去读盘没必要。
    /// 用锁而不是 `@MainActor`：鉴权发生在网络队列上。
    nonisolated(unsafe) private static var cached: String?
    private static let lock = NSLock()

    /// 当前 token，第一次用时生成并落盘。
    static func token() -> String {
        if let existing = lock.withLock({ cached }) { return existing }
        if let onDisk = try? String(contentsOf: tokenPath, encoding: .utf8) {
            let trimmed = onDisk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lock.withLock { cached = trimmed }
                return trimmed
            }
        }
        return regenerate()
    }

    @discardableResult
    static func regenerate() -> String {
        let token = IntegrationToken.generate()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? token.write(to: tokenPath, atomically: true, encoding: .utf8)
        // token = 凭据：只有属主可读写。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: tokenPath.path)
        lock.withLock { cached = token }
        Log.write("integration: token 已生成 \(tokenPath.path)")
        return token
    }

    static func matches(_ candidate: String) -> Bool {
        IntegrationToken.matches(token(), candidate)
    }

    /// 把内嵌的 MCP 桥脚本写到 App 数据目录，返回路径。
    ///
    /// **每次调用都重写一遍** —— App 升级之后磁盘上那份自动跟着更新，
    /// 而用户注册进编码助手的那条路径保持不变。
    @discardableResult
    static func exportMCPScript() -> URL? {
        guard let source = Bundle.main.url(forResource: "inkfall-mcp", withExtension: "mjs"),
              let script = try? String(contentsOf: source, encoding: .utf8) else {
            Log.write("integration: 包里找不到 inkfall-mcp.mjs")
            return nil
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try script.write(to: mcpScriptPath, atomically: true, encoding: .utf8)
        } catch {
            Log.write("integration: 写 MCP 脚本失败 \(error)")
            return nil
        }
        return mcpScriptPath
    }

    /// 注册命令，设置页直接给用户复制。
    ///
    /// 路径**必须带引号** —— 它固定落在 `Library/Application Support/` 下，中间那个
    /// 空格会被 shell 劈成两段参数，node 于是去找 `…/Library/Application`，启动即退，
    /// 客户端只看得到 `MCP error -32000: Connection closed`，看不出是路径问题。
    static var registerCommand: String {
        "claude mcp add inkfall -- node \"\(mcpScriptPath.path)\""
    }
}
