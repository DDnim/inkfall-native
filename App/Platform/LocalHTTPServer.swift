import Foundation
import InkfallCore
import Network

/// 127.0.0.1:48765 上的本地 HTTP 服务（spec/04 §3）。
///
/// 传输层用系统自带的 `NWListener` —— 不引第三方 server 框架：这条服务只
/// 监听回环、只服务本机的 MCP 桥与 curl，而语法那一层已经在
/// `InkfallCore.LocalHTTPParser` 里被单测钉住了。
///
/// ⚠️ **必须只绑回环**。绑 0.0.0.0 就等于把用户的笔记读写权限挂到局域网上。
final class LocalHTTPServer: @unchecked Sendable {

    /// 处理一条请求。回调在**主 actor** 上跑（要读写笔记与会话状态）。
    typealias Handler = @MainActor (LocalHTTPRequest) -> (status: UInt16, body: String)

    private let port: UInt16
    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.inkfall.http", qos: .utility)

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    @discardableResult
    func start() -> Bool {
        guard listener == nil else { return true }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 只绑 127.0.0.1。
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: port)!)
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: Log.write("http: 已监听 127.0.0.1:\(self.port)")
                case .failed(let error): Log.write("http: 监听失败 \(error)")
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            return true
        } catch {
            // 端口被占（多半是 Tauri 版还开着）——不是致命错误，其余功能照常。
            Log.write("http: 起不来 \(error)")
            return false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    var isRunning: Bool { listener?.state == .ready }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil {
                connection.cancel()
                return
            }

            let (outcome, _) = LocalHTTPParser.parse(buffer)
            switch outcome {
            case .incomplete:
                guard !isComplete else {
                    connection.cancel()
                    return
                }
                self.receive(connection, buffer: buffer)
            case .failure(let status, let message):
                self.respond(connection, status: status,
                             body: "{\"ok\":false,\"message\":\"\(message)\"}")
            case .request(let request):
                let handler = self.handler
                Task { @MainActor in
                    let (status, body) = handler(request)
                    self.respond(connection, status: status, body: body)
                }
            }
        }
    }

    /// 一问一答就关连接（`Connection: close`）—— 客户端全是 curl 与 MCP 桥的
    /// 一次性请求，keep-alive 只会多一份状态机要维护。
    private func respond(_ connection: NWConnection, status: UInt16, body: String) {
        let payload = Data(body.utf8)
        let head = """
        HTTP/1.1 \(status) \(Self.reason(status))\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(payload.count)\r
        Connection: close\r
        \r

        """
        var response = Data(head.utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reason(_ status: UInt16) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        default: return "Error"
        }
    }
}
