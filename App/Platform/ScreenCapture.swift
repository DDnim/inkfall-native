import AppKit
import CoreGraphics
import Foundation

/// 截图。
///
/// 直接调系统的 `/usr/sbin/screencapture`，不自己搓 ScreenCaptureKit ——
/// 框选的那套交互（十字光标、拖拽、空格拖动选区、Esc 取消、多显示器）
/// 系统已经做好了，自己重做一遍只会做得更差，而且要自己画覆盖窗口、
/// 处理刘海屏与缩放。
///
/// 屏幕录制权限归属**责任进程**，也就是 Inkfall 自己 —— 子进程不会
/// 单独出现在系统设置里。
enum ScreenCapture {

    enum Mode {
        /// 框选一块区域（⌥;）。用户可以按 Esc 取消。
        case region
        /// 整块主屏（⌥'）。
        case fullScreen
    }

    enum Failure: LocalizedError {
        case notAuthorized
        case cancelled
        case failed(Int32)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "未授权屏幕录制"
            case .cancelled: return "已取消"
            case .failed(let code): return "截图失败（\(code)）"
            }
        }
    }

    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// 请求授权。**首次调用才会弹系统对话框**，之后只能靠用户去设置里勾。
    @discardableResult
    static func requestAuthorization() -> Bool { CGRequestScreenCaptureAccess() }

    /// 截一张图写到 `url`。
    ///
    /// ⚠️ 阻塞直到用户框完或取消 —— 框选本来就是同步交互。调用方必须放后台队列。
    static func capture(_ mode: Mode, to url: URL) throws {
        guard isAuthorized else { throw Failure.notAuthorized }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x 不放快门声（这是个常驻小工具，不该每次截图都响一下）
        // -r 不带窗口阴影与元数据
        var args = ["-x", "-r"]
        if mode == .region { args.append("-i") }   // -i 进入框选交互
        args.append(url.path)
        process.arguments = args

        try process.run()
        process.waitUntilExit()

        // 用户按 Esc 取消时 screencapture 照样返回 0，但**不会写出文件**。
        // 所以判据是「文件存不存在」，不是退出码。
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw process.terminationStatus == 0
                ? Failure.cancelled : Failure.failed(process.terminationStatus)
        }
    }
}

/// 笔记的图片附件。
///
/// 正文里写的是 markdown 的 `![](file://…)`（spec/03），所以图片必须落成
/// 真实文件，且路径要稳定 —— 笔记会长期存在，不能指向临时目录。
enum NoteAttachments {

    static let root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/app.inkfall.native/attachments")

    /// 每篇笔记一个目录，删笔记时可以整个目录一起删掉。
    static func directory(for noteID: String) -> URL {
        root.appendingPathComponent(noteID)
    }

    /// 为一张新截图分配路径（还没有文件）。
    static func newImageURL(noteID: String) throws -> URL {
        let dir = directory(for: noteID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shot-\(UUID().uuidString.prefix(8)).png")
    }

    static func removeAll(noteID: String) {
        try? FileManager.default.removeItem(at: directory(for: noteID))
    }

    /// 插进正文的 markdown 片段。
    ///
    /// 用绝对 `file://` URL 而不是相对路径：正文会被复制、导出、粘进别的
    /// 编辑器，相对路径一离开这个目录就断了。
    static func markdown(for url: URL) -> String {
        "![截图](\(url.absoluteString))"
    }
}
