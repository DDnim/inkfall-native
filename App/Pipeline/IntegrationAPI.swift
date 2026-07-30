import AppKit
import Foundation
import InkfallCore

/// 本地 HTTP 的路由与处理（spec/04 §3）。
///
/// 两套路由，两种门禁：
/// - `/api/*` —— 集成 API。**双重门禁**：设置里的开关必须开（否则 403），
///   且 `Authorization: Bearer <integration_token>` 必须匹配（否则 401）。
/// - `/debug/*` —— 开发工具。**无鉴权是刻意的**（只监听回环），
///   但它能触发录音、读写笔记，所以这里只开放**只读或明显无害**的那些，
///   写操作一律走 `/api/*`。这是对 spec/04 §3.2 那句「重写时应重新评估」的回答。
@MainActor
final class IntegrationAPI {

    private let store: SettingsStore
    private let notes: NoteStore
    private let session: NoteSessionController
    private let jarvis: JarvisController
    private let notch: NotchOverlayController
    private let permissions: PermissionCoordinator

    init(store: SettingsStore, notes: NoteStore, session: NoteSessionController,
         jarvis: JarvisController, notch: NotchOverlayController,
         permissions: PermissionCoordinator) {
        self.store = store
        self.notes = notes
        self.session = session
        self.jarvis = jarvis
        self.notch = notch
        self.permissions = permissions
    }

    // MARK: - 入口

    func handle(_ request: LocalHTTPRequest) -> (status: UInt16, body: String) {
        let path = request.path
        if path == "/" || path == "/health" { return health() }
        if path.hasPrefix("/api/") { return api(request) }
        if path.hasPrefix("/debug/") { return debug(request) }
        return error(404, "unknown route")
    }

    // MARK: - /health

    private func health() -> (UInt16, String) {
        ok([
            "app": "Inkfall Native",
            "notes": notes.notes.count,
            "recording": session.isRecording,
            "notePaused": session.isPaused,
            "jarvisScanning": jarvis.scanning,
            "integrationApiEnabled": store.settings.integrationApiEnabled,
            "permissions": [
                "accessibility": permissions.isGranted(.accessibility),
                "microphone": permissions.isGranted(.microphone),
                "screenRecording": permissions.isGranted(.screenRecording),
            ],
            "shortcuts": [
                "hold": store.effectiveShortcuts.overlayHold.displayLabel,
                "note": store.effectiveShortcuts.noteMode.displayLabel,
                "flush": store.effectiveShortcuts.flushSegment.displayLabel,
                "cancel": store.effectiveShortcuts.cancelRecording.displayLabel,
                "jarvis": "Right Option + ,",
            ],
        ])
    }

    // MARK: - /api/notes

    private func api(_ request: LocalHTTPRequest) -> (UInt16, String) {
        // 门禁一：功能开关。这条 API 把笔记读写敞给任何持 token 的本地进程。
        guard store.settings.integrationApiEnabled else {
            return error(403, "集成 API 没开（设置 → 集成）")
        }
        // 门禁二：bearer token。
        guard let candidate = request.bearerToken, IntegrationStore.matches(candidate) else {
            return error(401, "missing or invalid bearer token")
        }
        guard let route = IntegrationRoute.match(method: request.method, path: request.path) else {
            return error(404, "unknown route")
        }

        switch route {
        case .list:
            let list = notes.notes.map { entry -> [String: Any] in
                [
                    "id": entry.id,
                    "title": entry.title,
                    "createdAtMs": entry.createdAtMs,
                    "preview": String(entry.displayText.prefix(120)),
                ]
            }
            return ok(["notes": list])

        case .read(let id):
            guard let entry = notes.note(id: id) else { return error(404, "note not found") }
            return ok(["note": [
                "id": entry.id,
                "title": entry.title,
                "createdAtMs": entry.createdAtMs,
                "text": entry.displayText,
                "sourceText": entry.sourceText,
            ]])

        case .create:
            guard let payload = json(request.body) else { return error(400, "body must be JSON") }
            guard let text = payload["text"] as? String else {
                return error(400, "missing field: text")
            }
            let now = HistoryEntry.nowMs()
            let title = (payload["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = HistoryEntry(
                id: UUID().uuidString.uppercased(), createdAtMs: now,
                title: (title?.isEmpty == false ? title! : HistoryEntry.defaultTitle(now)),
                sourceText: text, finalText: text,
                transcriptionMode: store.settings.transcriptionMode,
                postProcessingEnabled: false)
            notes.upsert(entry)
            return (201, encode(["ok": true, "note": ["id": entry.id, "title": entry.title]]))

        case .update(let id):
            guard let payload = json(request.body) else { return error(400, "body must be JSON") }
            let title = payload["title"] as? String
            let text = payload["text"] as? String
            guard title != nil || text != nil else {
                return error(400, "nothing to update: pass title and/or text")
            }
            guard var entry = notes.note(id: id) else { return error(404, "note not found") }
            if let title { entry.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let text { entry.finalText = text }
            notes.upsert(entry)
            // 改的是当前会话那一篇时，面板上的标题/正文也要跟着走 ——
            // 否则面板下一次防抖落盘会把这次改动整个盖掉。
            if session.noteID == id {
                if let title { session.title = title }
                if let text, !session.isLive {
                    session.draft = text
                    session.commitDraft()
                }
            }
            return ok([:])

        case .delete(let id):
            guard notes.note(id: id) != nil else { return error(404, "note not found") }
            notes.remove(id: id)
            NoteAttachments.removeAll(noteID: id)
            // 删掉的是当前会话那一篇：**解绑 session**，否则面板会继续
            // 往一个幽灵条目上追加，下一次落盘又把它整个复活。
            if session.noteID == id { session.detachDeletedNote() }
            return ok([:])
        }
    }

    // MARK: - /debug

    /// 只读的观测面。
    ///
    /// 屏幕捕获受 TCC 限制、刘海又是 click-through 的，所以「它到底渲染成
    /// 什么样」只能靠这条通道取证 —— 这正是「UI 改动没有端到端验证就不算完成」
    /// 那条规则能落地的手段（spec/04 §3.2）。
    private func debug(_ request: LocalHTTPRequest) -> (UInt16, String) {
        switch request.path {
        case "/debug/note/state":
            return ok([
                "noteID": session.noteID ?? "",
                "mode": "\(session.mode)",
                "segments": session.segments.count,
                "inFlight": session.inFlight,
                "elapsed": session.elapsedSeconds,
                "hasUnpasted": session.hasUnpasted,
                "scanArmed": session.scanArmed,
                "body": session.body,
            ])

        case "/debug/overlay/state":
            return ok([
                "visible": notch.isVisible,
                "compact": notch.debugIsCompact,
                "armed": notch.debugArmed,
                "message": notch.debugMessage,
                "hover": notch.debugHover,
                "acceptsClicks": notch.debugAcceptsClicks,
                "capsule": notch.debugCapsule,
            ])

        case "/debug/jarvis/state":
            return ok([
                "scanning": jarvis.scanning,
                "owningRecorder": jarvis.owningRecorder,
                "discarded": jarvis.discarded,
                "pending": jarvis.debugPendingShell ?? "",
                "grabsEscape": jarvis.debugGrabsEscape,
                "featureEnabled": store.settings.jarvisModeEnabled
                    && store.settings.voiceCommandsEnabled,
                "askModeEnabled": store.settings.askModeEnabled,
                "claude": ClaudeCodeAgent.readiness,
                // 这几个字段决定了「助手到底能干什么」——查一次权限问题就得看到它们。
                "commands": store.settings.voiceCommands.map { command in
                    [
                        "keyword": command.keyword,
                        "template": command.commandTemplate,
                        "runner": command.runner.rawValue,
                        "terminal": command.terminal.rawValue,
                        "position": command.keywordPosition.rawValue,
                        "enabled": command.enabled,
                        "allowWebTools": command.allowWebTools,
                        "skipPermissions": command.skipPermissions,
                        "continuous": command.continuousConversation,
                    ]
                },
            ])

        // 干跑：只算「这句话会不会命中、命令展开成什么」，**不执行**。
        case "/debug/jarvis/match":
            let text = request.query["text"] ?? ""
            return ok(["text": text, "result": jarvis.debugMatch(text)])

        // 走**真实**的分发路径（不是复制品）—— 这条路由存在的全部意义就是
        // 让被验证的那条链和用户按键走的是同一条。
        case "/debug/jarvis/take":
            let text = request.query["text"] ?? ""
            guard jarvis.scanning else { return error(400, "贾维斯没在待命") }
            let hit = jarvis.dispatch(text)
            return ok(["text": text, "hit": hit, "pending": jarvis.debugPendingShell ?? ""])

        case "/debug/jarvis/toggle":
            let message = jarvis.toggle()
            return ok(["message": message ?? "", "scanning": jarvis.scanning])

        case "/debug/screenshot":
            let path = request.query["path"] ?? "/tmp/inkfall-native-shot.png"
            guard ScreenCapture.isAuthorized else { return error(403, "没有屏幕录制授权") }
            do {
                try ScreenCapture.capture(.fullScreen, to: URL(fileURLWithPath: path))
                return ok(["path": path])
            } catch let failure {
                // `error` 这个名字被上面的 catch 绑定遮住了，所以显式改名。
                return error(500, "\(failure)")
            }

        default:
            return error(404, "unknown debug route")
        }
    }

    // MARK: - JSON

    private func json(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func ok(_ payload: [String: Any]) -> (UInt16, String) {
        var merged = payload
        merged["ok"] = true
        return (200, encode(merged))
    }

    private func error(_ status: UInt16, _ message: String) -> (UInt16, String) {
        (status, encode(["ok": false, "message": message]))
    }

    private func encode(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"message\":\"encode failed\"}"
        }
        return text
    }
}
