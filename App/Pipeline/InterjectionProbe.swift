import Foundation
import InkfallCore

/// 试做：切换录音的每一段转写完，旁路问「说错了没有」，说错了就在刘海上纠正一句。
///
/// 两步：Jev 的门（说完了吗 / 有没有可核对的事实，一次请求）→ 过门才用加工模型另发
/// 一次核对。**绝不改变粘贴行为**，也不等它：粘贴照常走，纠正晚一两秒出来。
/// 没有 TypeSafe key、加工关着 / 本地预设 / 没配加工的 key，整条关掉。
@MainActor
final class InterjectionProbe {

    struct Outcome: Sendable {
        var segment: String
        var gate: InterjectionAPI.Gate?
        var check: InterjectionAPI.Check?
        /// 为什么停在这一步（日志用）
        var stoppedAt: String?
        var gateMs = 0
        var checkMs = 0
        var route = ""
    }

    /// Jev 最多等这么久（p90 226ms）。
    static let gateTimeout: TimeInterval = 0.8
    /// 核对最多等这么久。再晚 `InterjectionPolicy.maxDelay` 也会把它丢掉。
    static let checkTimeout: TimeInterval = 4.5
    /// 带给模型的前文段数。
    static let contextSegments = 3

    private static let gateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = gateTimeout
        configuration.timeoutIntervalForResource = gateTimeout
        return URLSession(configuration: configuration)
    }()

    private let keys = APIKeyStore.shared
    private var recent: [String] = []
    /// Jev 说「没说完」的半句，拼到下一段前面再问。
    private var fragment = ""
    private(set) var policy = InterjectionPolicy()
    /// 这一段之后又转写出来的话（给策略看本人有没有改口）。按段序号存。
    private var transcribed: [(index: Int, text: String)] = []
    private var counter = 0

    private lazy var typesafeKey: String? = {
        if let env = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !env.isEmpty { return env }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/typesafe/api_key")
        let raw = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }()

    var hasGateKey: Bool { typesafeKey != nil }

    /// 长录音开始时清掉上一场的前文。
    func reset() {
        recent = []
        fragment = ""
        transcribed = []
    }

    /// 一段转写好了：登记下来，返回它的序号（之后问策略时用）。
    func register(_ text: String) -> Int {
        counter += 1
        transcribed.append((counter, text))
        if transcribed.count > 20 { transcribed.removeFirst(transcribed.count - 20) }
        return counter
    }

    func segments(after index: Int) -> [String] {
        transcribed.filter { $0.index > index }.map(\.text)
    }

    /// 核对要用的路：加工的 provider / model（按当前预设）/ key。拿不到就是 nil（整条关）。
    func checkRoute(settings: AppSettings) async -> PostProcessor.Route? {
        guard settings.postProcessingEnabled, !settings.postProcessingPreset.isLocal else { return nil }
        let provider = settings.postProcessingProvider
        guard let key = await keys.resolve(provider) else { return nil }
        return .cloud(provider: provider, model: settings.postProcessingModel(for: settings.postProcessingPreset), key: key)
    }

    /// 实际使用的一次：维护前文和半句，失败一律当「不插」。
    func run(segment raw: String, settings: AppSettings) async -> Outcome {
        let segment = fragment.isEmpty ? raw : fragment + raw
        let previous = Array(recent.suffix(Self.contextSegments))
        let outcome = await judge(segment: segment, previous: previous, route: await checkRoute(settings: settings))
        if let gate = outcome.gate, !gate.isComplete {
            fragment = segment
        } else {
            fragment = ""
            recent.append(segment)
            if recent.count > Self.contextSegments { recent.removeFirst(recent.count - Self.contextSegments) }
        }
        return outcome
    }

    /// 无状态的一次判定（自测和评测也走这里）。`route == nil` 就只问 Jev。
    func judge(segment: String, previous: [String], route: PostProcessor.Route?,
               skipGate: Bool = false) async -> Outcome {
        var outcome = Outcome(segment: segment)
        if !skipGate {
            guard let key = typesafeKey else { outcome.stoppedAt = "no-typesafe-key"; return outcome }
            let started = CFAbsoluteTimeGetCurrent()
            outcome.gate = await gate(key: key, previous: previous, segment: segment)
            outcome.gateMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            guard let gate = outcome.gate else { outcome.stoppedAt = "gate-failed"; return outcome }
            guard gate.isComplete else { outcome.stoppedAt = "incomplete"; return outcome }
            guard gate.passes else { outcome.stoppedAt = "no-claim"; return outcome }
        }
        guard let route else { outcome.stoppedAt = "no-check-route"; return outcome }
        if case .cloud(let provider, let model, _) = route { outcome.route = "\(provider.label)/\(model)" }
        let started = CFAbsoluteTimeGetCurrent()
        let result = await withTimeout(Self.checkTimeout) {
            await PostProcessor.run(.init(instructions: InterjectionAPI.checkInstructions,
                                          input: InterjectionAPI.checkInput(previous: previous, segment: segment),
                                          route: route))
        }
        outcome.checkMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        switch result {
        case .none:
            outcome.stoppedAt = "check-timeout"
        case .some(.failure(let failure)):
            Log.write("interject: 核对失败 \(failure.message)")
            outcome.stoppedAt = "check-failed"
        case .some(.success(let success)):
            do {
                outcome.check = try InterjectionAPI.parseCheck(success.text)
            } catch {
                Log.write("interject: 核对回答解析失败 \(success.text.prefix(200))")
                outcome.stoppedAt = "check-unparsable"
            }
        }
        return outcome
    }

    /// 策略裁决（有状态：冷却、去重）。
    func decide(_ check: InterjectionAPI.Check, delay: TimeInterval, laterSegments: [String]) -> InterjectionPolicy.Decision {
        policy.decide(check, delay: delay, laterSegments: laterSegments, now: Date())
    }

    private func gate(key: String, previous: [String], segment: String) async -> InterjectionAPI.Gate? {
        guard let body = InterjectionAPI.gateBody(previous: previous, segment: segment) else { return nil }
        var request = URLRequest(url: AssistantIntentAPI.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        for (field, value) in AssistantIntentAPI.headers(key: key) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await Self.gateSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                Log.write("interject: Jev HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))")
                return nil
            }
            return try InterjectionAPI.parseGate(data)
        } catch {
            Log.write("interject: Jev 失败 \(error.localizedDescription)")
            return nil
        }
    }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                          _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
