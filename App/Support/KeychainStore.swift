import Foundation
import InkfallCore

/// 三把云端 API key 的钥匙串读写。
///
/// ⚠️ 走 `/usr/bin/security` CLI 而**不是** Security framework（spec/02 §7）。
/// 原因不是偷懒：CLI 读老式 login keychain 不会弹「允许访问」对话框，而
/// `add-generic-password -A`（allow-all ACL）让**重新构建过的**二进制仍然
/// 静默读得到同一条目 —— legacy keychain 把静默访问权绑在创建条目的那个
/// 二进制上，开发期每改一行就换一次 CDHash，framework 那条路会天天弹框。
/// spec/10 B8 允许重写时改回 framework，但要求先验证「重建后不弹框」；
/// 在那个验证做完之前，这里保持 CLI。
enum KeychainStore {

    /// 沿用 Tauri 版的 service，原生版直接读得到用户已有的 key。
    static let service = "app.inkfall.desktop"

    static func account(for provider: CloudProvider) -> String {
        switch provider {
        case .openai: return "openai_api_key"
        case .groq: return "groq_api_key"
        case .gemini: return "gemini_api_key"
        }
    }

    static func read(_ provider: CloudProvider) -> String? {
        guard let output = run(["find-generic-password",
                                "-s", service, "-a", account(for: provider), "-w"]) else {
            return nil
        }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    @discardableResult
    static func write(_ value: String, for provider: CloudProvider) -> Bool {
        let account = account(for: provider)
        // 先删再加：`-U` 单独用会保留旧条目的 ACL，而我们要的是「这次构建
        // 创建的条目」。删不掉（不存在）是正常情况，不看返回值。
        _ = run(["delete-generic-password", "-s", service, "-a", account])
        return run(["add-generic-password",
                    "-s", service, "-a", account,
                    "-l", "Inkfall \(provider.label) API Key",
                    "-w", value, "-A", "-U"]) != nil
    }

    static func delete(_ provider: CloudProvider) {
        _ = run(["delete-generic-password", "-s", service, "-a", account(for: provider)])
    }

    /// exit 44 = 条目不存在，对删除来说等于成功；这里统一按「没拿到输出」处理。
    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 进程内的 key 缓存。
///
/// 解析顺序是 spec/05 §5 的：**环境变量 → Keychain**。
/// 加工发生在「用户刚说完话、正等着文字落下来」的时刻，那条路上绝不能
/// fork 一个 `security` 去阻塞；所以启动时按 `activeCloudProviders` 预热，
/// 之后只读缓存。
@MainActor
@Observable
final class APIKeyStore {

    static let shared = APIKeyStore()

    private var cache: [CloudProvider: String] = [:]
    /// 已经问过钥匙串的供应商（问过但没有，和没问过，是两回事）。
    private var probed: Set<CloudProvider> = []

    private init() {}

    /// 启动时（以及保存设置后）预热。只碰这份配置真的会用到的供应商 ——
    /// 每个供应商都读一遍等于凭空多两次钥匙串访问。
    func preload(_ providers: Set<CloudProvider>) {
        for provider in providers where !probed.contains(provider) {
            Task.detached(priority: .utility) {
                let value = KeychainStore.read(provider)
                await MainActor.run { APIKeyStore.shared.adopt(value, for: provider) }
            }
        }
    }

    /// 拿这次请求要用的 key。缓存没热就现读一次（在后台线程上，
    /// 调用方是异步任务，不会挡住界面）。
    func resolve(_ provider: CloudProvider) async -> String? {
        if let key = environmentKey(provider) { return key }
        if let cached = cache[provider] { return cached }
        if probed.contains(provider) { return nil }
        let value = await Task.detached(priority: .userInitiated) {
            KeychainStore.read(provider)
        }.value
        adopt(value, for: provider)
        return cache[provider]
    }

    /// 界面用：这个供应商配没配过 key。**不触发**钥匙串读取 ——
    /// 设置页每次重绘都去 fork 一个 security 是不可接受的。
    func isConfigured(_ provider: CloudProvider) -> Bool {
        environmentKey(provider) != nil || cache[provider] != nil
    }

    /// 界面用的遮罩显示。没有就是 nil。
    func maskedKey(_ provider: CloudProvider) -> String? {
        guard let key = environmentKey(provider) ?? cache[provider] else { return nil }
        return APIKeyNormalization.masked(key)
    }

    /// key 是环境变量给的（那就不该让用户在设置页里「删除」）。
    func isFromEnvironment(_ provider: CloudProvider) -> Bool {
        environmentKey(provider) != nil
    }

    /// 保存用户粘进来的东西。归一化失败就抛 —— 让错误当场可见，
    /// 而不是等到下一次听写时变成一个看不懂的 401。
    func save(_ raw: String, for provider: CloudProvider) throws {
        let normalized = try APIKeyNormalization.normalized(raw, provider: provider)
        guard KeychainStore.write(normalized, for: provider) else {
            throw KeyStoreFailure.keychainWriteFailed
        }
        cache[provider] = normalized
        probed.insert(provider)
        Log.write("keys: 已保存 \(provider.rawValue) key（\(APIKeyNormalization.masked(normalized))）")
    }

    func clear(_ provider: CloudProvider) {
        KeychainStore.delete(provider)
        cache[provider] = nil
        probed.insert(provider)
        Log.write("keys: 已删除 \(provider.rawValue) key")
    }

    enum KeyStoreFailure: LocalizedError {
        case keychainWriteFailed
        var errorDescription: String? { "写入钥匙串失败" }
    }

    private func adopt(_ value: String?, for provider: CloudProvider) {
        probed.insert(provider)
        // 盘上存的可能是很久以前、归一化规则还没上线时写进去的。
        guard let value,
              let normalized = try? APIKeyNormalization.normalized(value, provider: provider) else {
            cache[provider] = nil
            return
        }
        cache[provider] = normalized
    }

    private func environmentKey(_ provider: CloudProvider) -> String? {
        let name = APIKeyNormalization.environmentVariableName(provider)
        guard let raw = ProcessInfo.processInfo.environment[name],
              let normalized = try? APIKeyNormalization.normalized(raw, provider: provider) else {
            return nil
        }
        return normalized
    }
}
