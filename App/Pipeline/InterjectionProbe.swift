import Foundation
import InkfallCore

/// 试做：助手模式的分流与执行。每段转写完问 Jev 一次（见 `InterjectionAPI`），再按分流：
/// 简单问题用加工模型回答、事实用加工模型核对；交给 agent / 起票面板的由调用方发给看板。
/// 输入模式不走这里。
/// 没有 TypeSafe key 就不分流（只记历史）；没配加工那家的 key 就不回答、不核对。
@MainActor
final class InterjectionProbe {

    struct Outcome: Sendable {
        var segment: String
        var gate: InterjectionAPI.Gate?
        var route: InterjectionAPI.Route = .none
        var check: InterjectionAPI.Check?
        var answer: String?
        /// 为什么停在这一步（日志用）
        var stoppedAt: String?
        var gateMs = 0
        var checkMs = 0
        var model = ""

        init(segment: String, gate: InterjectionAPI.Gate? = nil, route: InterjectionAPI.Route = .none,
             stoppedAt: String? = nil, gateMs: Int = 0) {
            self.segment = segment
            self.gate = gate
            self.route = route
            self.stoppedAt = stoppedAt
            self.gateMs = gateMs
        }
    }

    /// Jev 最多等这么久（p90 226ms）。
    static let gateTimeout: TimeInterval = 0.8
    /// 核对最多等这么久。再晚 `InterjectionPolicy.maxDelay` 也会把它丢掉。
    static let checkTimeout: TimeInterval = 4.5
    /// 回答是用户在等的，可以久一点。
    static let answerTimeout: TimeInterval = 10
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

    /// 核对 / 回答要用的路：有 Groq key 就用 Groq 的 Qwen（2026-09-30 境），
    /// 否则加工的 provider / model（按当前预设）/ key。都没有 key 就是 nil（整条关）。
    ///
    /// ⚠️ 不看加工开没开、预设是不是本地的 basic：境平常就用 basic（本地润色，不上云），
    /// 早先这里要求云端预设，结果真机上每段都停在 no-check-route，一次也没核对过。
    /// basic 也有自己那一档的模型配置（`postProcessingPresetModels.basic`），照用。
    /// - `preferQwen`: 评测按 `--provider` 比别家时关掉
    func checkRoute(settings: AppSettings, preferQwen: Bool = true) async -> PostProcessor.Route? {
        if preferQwen, let key = await keys.resolve(InterjectionAPI.checkProvider) {
            return .cloud(provider: InterjectionAPI.checkProvider, model: InterjectionAPI.checkModel, key: key)
        }
        let provider = settings.postProcessingProvider
        guard let key = await keys.resolve(provider) else { return nil }
        return .cloud(provider: provider, model: settings.postProcessingModel(for: settings.postProcessingPreset), key: key)
    }

    /// 助手模式的一段：Jev 分流 → 回答 / 核对（任务由调用方交给看板）。维护前文和半句。
    /// - `checkComplete`: 切换录音按停顿切出的段才看「说完了吗」。
    func run(segment raw: String, settings: AppSettings, checkComplete: Bool) async -> Outcome {
        let segment = fragment.isEmpty ? raw : fragment + raw
        guard typesafeKey != nil else { return Outcome(segment: segment, stoppedAt: "no-typesafe-key") }
        let started = CFAbsoluteTimeGetCurrent()
        let gate = await askGate(segment: segment)
        let gateMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        guard let gate else { return Outcome(segment: segment, stoppedAt: "gate-failed", gateMs: gateMs) }
        // 半句只接一次：接上之后还判没说完就照样往下走。原来一直接，一句「没说完」之后每段都接在它后面，
        // 越接越长、永远判不成说完，后面说的全丢了（2026-10-01 真机：之后八句错话一句没纠正）
        if fragment.isEmpty, gate.route(checkComplete: checkComplete) == .incomplete {
            fragment = segment
            return Outcome(segment: segment, gate: gate, route: .incomplete, gateMs: gateMs)
        }
        fragment = ""
        var outcome = await act(segment: segment, gate: gate, settings: settings)
        outcome.gateMs = gateMs
        return outcome
    }

    /// 问 Jev 一次（六个问题）。前文用最近几句。
    /// - `live`: 边听边插话的 0.2 秒停顿（问法不同，见 `InterjectionAPI.liveCompleteQuestion`）
    func askGate(segment: String, live: Bool = false) async -> InterjectionAPI.Gate? {
        guard let key = typesafeKey else { return nil }
        return await gate(key: key, previous: Array(recent.suffix(Self.contextSegments)), segment: segment, live: live)
    }

    /// 已经问过 Jev、这句也收了（说完了或者硬收）：记进前文，按分流回答 / 核对。
    /// - `answering`: 回答 / 建卡要不要做（边听边插话只纠错：两个人聊天时的问题是问对方的，见 `Gate.liveRoute`）
    func act(segment: String, gate: InterjectionAPI.Gate, settings: AppSettings, answering: Bool = true) async -> Outcome {
        let previous = Array(recent.suffix(Self.contextSegments))
        var outcome = Outcome(segment: segment, gate: gate)
        outcome.route = answering ? gate.route(checkComplete: false) : gate.liveRoute
        recent.append(segment)
        if recent.count > Self.contextSegments { recent.removeFirst(recent.count - Self.contextSegments) }

        switch outcome.route {
        case .answer:
            guard let route = await checkRoute(settings: settings) else { outcome.stoppedAt = "no-check-route"; break }
            outcome.model = Self.label(route)
            let t0 = CFAbsoluteTimeGetCurrent()
            let result = await withTimeout(Self.answerTimeout) {
                await PostProcessor.run(.init(instructions: InterjectionAPI.answerInstructions,
                                              input: InterjectionAPI.answerInput(previous: previous, question: segment),
                                              route: route, maxOutputTokens: InterjectionAPI.answerMaxOutputTokens))
            }
            outcome.checkMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            switch result {
            case .none: outcome.stoppedAt = "answer-timeout"
            case .some(.failure(let failure)):
                Log.write("assistant: 回答失败 \(failure.message)")
                outcome.stoppedAt = "answer-failed"
            case .some(.success(let success)):
                let answer = InterjectionAPI.cleanAnswer(success.text)
                if answer.isEmpty { outcome.stoppedAt = "answer-empty" } else { outcome.answer = answer }
            }
        case .check:
            await check(&outcome, previous: previous, route: await checkRoute(settings: settings))
        case .agent, .ticket, .none, .incomplete:
            break
        }
        return outcome
    }

    /// 无状态的一次核对（自测和评测走这里）。`route == nil` 就只问 Jev。
    func judge(segment: String, previous: [String], route: PostProcessor.Route?,
               skipGate: Bool = false) async -> Outcome {
        var outcome = Outcome(segment: segment)
        if !skipGate {
            guard let key = typesafeKey else { outcome.stoppedAt = "no-typesafe-key"; return outcome }
            let started = CFAbsoluteTimeGetCurrent()
            outcome.gate = await gate(key: key, previous: previous, segment: segment, live: false)
            outcome.gateMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            guard let gate = outcome.gate else { outcome.stoppedAt = "gate-failed"; return outcome }
            outcome.route = gate.route(checkComplete: true)
            guard gate.isComplete else { outcome.stoppedAt = "incomplete"; return outcome }
            guard gate.passes else { outcome.stoppedAt = "no-claim"; return outcome }
        }
        await check(&outcome, previous: previous, route: route)
        return outcome
    }

    private func check(_ outcome: inout Outcome, previous: [String], route: PostProcessor.Route?) async {
        guard let route else { outcome.stoppedAt = "no-check-route"; return }
        outcome.model = Self.label(route)
        let segment = outcome.segment
        let started = CFAbsoluteTimeGetCurrent()
        let result = await withTimeout(Self.checkTimeout) {
            await PostProcessor.run(.init(instructions: InterjectionAPI.checkInstructions,
                                          input: InterjectionAPI.checkInput(previous: previous, segment: segment),
                                          route: route, maxOutputTokens: InterjectionAPI.checkMaxOutputTokens,
                                          temperature: InterjectionAPI.checkTemperature(for: route.provider)))
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
    }

    private static func label(_ route: PostProcessor.Route) -> String {
        if case .cloud(let provider, let model, _) = route { return "\(provider.label)/\(model)" }
        return ""
    }

    /// 策略裁决（有状态：冷却、去重）。
    func decide(_ check: InterjectionAPI.Check, segment: String, delay: TimeInterval,
                laterSegments: [String]) -> InterjectionPolicy.Decision {
        policy.decide(check, segment: segment, delay: delay, laterSegments: laterSegments, now: Date())
    }

    /// 先把到 Jev 的连接握好（边听边插话开录时调）。
    func prewarm() {
        guard typesafeKey != nil else { return }
        var request = URLRequest(url: AssistantIntentAPI.endpoint)
        request.httpMethod = "HEAD"
        Self.gateSession.dataTask(with: request).resume()
    }

    private func gate(key: String, previous: [String], segment: String, live: Bool) async -> InterjectionAPI.Gate? {
        guard let body = InterjectionAPI.gateBody(previous: previous, segment: segment, live: live) else { return nil }
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
