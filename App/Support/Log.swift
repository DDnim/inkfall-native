import Foundation

/// 调试日志。
///
/// 专用串行队列追加写，**慢磁盘不阻塞调用方** —— 渲染回调与热键 tap 都可能
/// 打日志，它们一卡就是丢音频或丢按键。
///
/// 路径刻意区别于 Tauri 版的 `/tmp/inkfall-debug.log`，两个版本可以同时跑
/// 而不交错写同一个文件。
enum Log {
    static let path = "/tmp/inkfall-native.log"

    private static let queue = DispatchQueue(label: "app.inkfall.log", qos: .utility)
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// 等待队列排空。`exit()` 会直接掐掉进程，自测的结论行否则会丢。
    static func flush() {
        queue.sync {}
    }

    static func write(_ message: String) {
        let stamp = formatter.string(from: Date())
        let line = "\(stamp) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
