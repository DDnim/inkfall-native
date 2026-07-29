import Foundation

/// 纯粹、可测的自动断句状态机（与 inkfall-mobile 同参、同算法）。
///
/// 调用方每帧喂一个麦克风电平 + 距上一帧的时间，它只回答一个问题：
/// **现在该切段了吗？** 所有音频与 UI 副作用都在调用方，这里只有计时状态，
/// 因此不需要 CoreAudio 就能单测。
///
/// 策略（逐停顿切，与移动端一致）：
/// 1. 静音计时器**只有在本段累计了足够真实语音之后**才上膛，前导静音与
///    杂音永远不会切。
/// 2. 上膛之后，连续静音达到 `silenceCutSeconds` 触发**恰好一次**切段，
///    随即重置本段状态等待下一次发声。
/// 3. 语音中的短停顿（< 阈值）不切 —— 任何语音帧都会清零累计静音。
/// 4. 切完之后持续的静音不会再次触发，必须重新累计语音。
///
/// 语音/静音判定是**相对**的（自适应噪声底 + 进入/退出比例 + 迟滞），
/// 因此能适应不同硬件产生的绝对电平尺度，而不是靠一个固定阈值在
/// 安静/嘈杂环境里两头不讨好。
public struct SilenceSegmenterConfig: Sendable, Equatable {
    /// 上膛后需要连续静音多久才切（秒）。
    public var silenceCutSeconds: Double
    /// 本段累计语音达到多少秒，静音计时器才允许上膛。
    public var minSpeechSeconds: Double
    /// 绝对底线门限（归一化 0...1）。低于它一律算静音，这样死寂房间里
    /// 一个接近 0 的噪声底也不会把轻微嘶声当成语音。
    public var minSpeechLevel: Float
    /// 高于 `噪声底 × enterRatio`（且过绝对门限）→ 进入语音。
    public var enterRatio: Float
    /// 低于 `噪声底 × exitRatio` → 退出语音。比 enterRatio 小以形成迟滞，
    /// 电平在边界附近徘徊时不会来回抖。
    public var exitRatio: Float
    /// 噪声底**上升**的时间常数（秒）。慢，这样稳定的背景能被学到而不吞掉语音。
    public var floorRiseTimeConstant: Double
    /// 噪声底**下降**的时间常数（秒）。快，一口气之内就能找到真实背景。
    public var floorFallTimeConstant: Double
    /// 噪声底下限，保证相对阈值在极安静时仍然有限且稳定。
    public var floorEpsilon: Float
    /// 用第一帧播种噪声底时的上限，避免会话从说话中间开始时播下一个虚高的底。
    public var initialFloorSeed: Float
    /// 噪声底取「最近这么长时间里的最低电平」。见 `adaptNoiseFloor` 的说明。
    public var floorWindowSeconds: Double
    /// 进入语音需要连续超过阈值多久。**一帧尖峰不算说话** —— 停顿期间的
    /// 环境噪声是很尖的，没有这个起振时间，每个尖峰都会把静音计时器清零。
    public var speechAttackSeconds: Double
    /// 噪声底相对近期语音峰值的上限。防止「电平恒定的说话」把底噪一路抬到
    /// 语音本身的高度，进而把说话误判成静音。
    public var floorPeakCapRatio: Float
    /// 语音峰值记忆的衰减时间常数。
    public var speechPeakTimeConstant: Double

    public init(
        silenceCutSeconds: Double = 1.3,
        minSpeechSeconds: Double = 0.3,
        minSpeechLevel: Float = 0.005,
        enterRatio: Float = 2.2,
        exitRatio: Float = 1.5,
        floorRiseTimeConstant: Double = 2.0,
        floorFallTimeConstant: Double = 0.3,
        floorEpsilon: Float = 0.0008,
        initialFloorSeed: Float = 0.006,
        floorWindowSeconds: Double = 1.0,
        speechAttackSeconds: Double = 0.12,
        floorPeakCapRatio: Float = 0.15,
        speechPeakTimeConstant: Double = 4.0
    ) {
        self.silenceCutSeconds = silenceCutSeconds
        self.minSpeechSeconds = minSpeechSeconds
        self.minSpeechLevel = minSpeechLevel
        self.enterRatio = enterRatio
        self.exitRatio = exitRatio
        self.floorRiseTimeConstant = floorRiseTimeConstant
        self.floorFallTimeConstant = floorFallTimeConstant
        self.floorEpsilon = floorEpsilon
        self.initialFloorSeed = initialFloorSeed
        self.floorWindowSeconds = floorWindowSeconds
        self.speechAttackSeconds = speechAttackSeconds
        self.floorPeakCapRatio = floorPeakCapRatio
        self.speechPeakTimeConstant = speechPeakTimeConstant
    }

    public static let `default` = SilenceSegmenterConfig()
}

public struct SilenceSegmenter: Sendable {
    public let config: SilenceSegmenterConfig

    /// 本段累计语音时长；越过 `minSpeechSeconds` 后静音计时器上膛。
    private var speechAccumulated: Double = 0
    /// 当前这段连续静音的时长（说话时为 0）。
    private var currentSilence: Double = 0
    /// 背景噪声的滚动估计。向下降得快、向上升得慢，语音期间冻结（不让语音抬高底噪）。
    /// 跨切段保留，只有 `reset()` 会清掉。
    private var noiseFloor: Float = 0
    /// 迟滞状态：当前帧算不算语音。
    private var isInSpeech = false
    /// 噪声底是否已经用真实样本播种过。
    private var floorInitialized = false
    /// 当前统计窗口内的最低电平，以及窗口已累计的时长。
    private var windowMin: Float = 1
    private var windowElapsed: Double = 0
    /// 连续超过进入阈值的时长（起振计时）。
    private var aboveEnter: Double = 0
    /// 近期语音峰值的衰减记忆，给噪声底封顶用。
    private var speechPeak: Float = 0

    public init(config: SilenceSegmenterConfig = .default) {
        self.config = config
    }

    /// 喂一帧。`level` 是归一化电平，`delta` 是距上一帧的秒数。
    /// 返回 `true` 的那一帧，本段状态**已经**重置好，可以直接开下一段。
    public mutating func feed(level: Float, delta: Double) -> Bool {
        guard delta > 0 else { return false }

        // 冷启动：用第一帧播种噪声底（带上限），并当作静音 —— 还没有东西可上膛。
        if !floorInitialized {
            noiseFloor = max(config.floorEpsilon, min(level, config.initialFloorSeed))
            floorInitialized = true
            return false
        }

        // ⚠️ 顺序要紧，而且和旧版**相反**：先更新噪声底，再用新阈值判定语音。
        //
        // 旧版是「先判语音、后更新底噪」，配合「语音期间冻结底噪」才自洽。
        // 换成窗口最小值之后必须调过来：底噪要先吸收这一帧，语音判定才能用上
        // 追平环境之后的阈值。反过来会晚一个窗口，实测序列就切不出来。
        // （`speechPeak` 因此用的是**上一帧**的语音状态，这是有意的。）
        adaptNoiseFloor(level: level, delta: delta)
        updateSpeechState(level: level, delta: delta)

        if isInSpeech {
            speechAccumulated += delta
            currentSilence = 0
            return false
        }

        // 前导静音，或本段真实语音还不够：计时器未上膛，切不了。
        guard speechAccumulated >= config.minSpeechSeconds else { return false }

        currentSilence += delta
        if currentSilence >= config.silenceCutSeconds {
            // 每次停顿只切一次：重置，这样持续静音在新语音出现前不会再触发。
            resetSegment()
            return true
        }
        return false
    }

    /// 迟滞式相对语音判定。
    private mutating func updateSpeechState(level: Float, delta: Double) {
        if isInSpeech {
            if level < exitThreshold {
                isInSpeech = false
                aboveEnter = 0
            }
        } else if level > enterThreshold {
            // ⚠️ 起振时间：连续超过阈值 `speechAttackSeconds` 才算说话。
            // 少了它，停顿期间的一帧噪声尖峰就会把静音计时器清零 ——
            // 实测停顿的峰值能到 0.014 而最低只有 0.004，全靠这一条把尖峰滤掉。
            aboveEnter += delta
            if aboveEnter >= config.speechAttackSeconds { isInSpeech = true }
        } else {
            aboveEnter = 0
        }
    }

    /// 向下快、向上慢，且语音期间绝不上升。
    /// 噪声底 = **最近一个窗口里的最低电平**（minimum statistics）。
    ///
    /// ## 为什么不是「语音期间冻结」
    ///
    /// 旧做法只在 `!isInSpeech` 时让底噪上升。这会自锁：会话在真静音里起录，
    /// 底噪被播种在 epsilon（0.0008），退出语音的门槛因而被绝对下限钉在
    /// 0.0025；而真实停顿的最低电平是 0.0042 —— 永远出不了语音态，底噪也就
    /// 永远没机会上升去追环境。实测 17.6 秒、含一个 2.3 秒停顿的素材，
    /// 旧算法**一刀都切不出来**。
    ///
    /// 窗口最小值不受这个死锁影响：说话时的字间停顿天然提供最低点，
    /// 底噪照样能追上环境。
    ///
    /// ## 为什么要对语音峰值封顶
    ///
    /// 电平恒定的说话（合成音、稳定音量的朗读）会让窗口最小值等于语音本身，
    /// 底噪一路爬到语音高度，于是说话被判成静音、切出一堆假段。
    /// 所以底噪不得超过近期语音峰值的 `floorPeakCapRatio`。
    private mutating func adaptNoiseFloor(level: Float, delta: Double) {
        // 语音峰值的衰减记忆。
        let decay = Float(exp(-delta / config.speechPeakTimeConstant))
        speechPeak = max(speechPeak * decay, isInSpeech ? level : 0)

        windowMin = min(windowMin, level)
        windowElapsed += delta
        guard windowElapsed >= config.floorWindowSeconds else { return }

        var target = windowMin
        if speechPeak > 0 {
            target = min(target, speechPeak * config.floorPeakCapRatio)
        }
        let tau = target < noiseFloor
            ? config.floorFallTimeConstant : config.floorRiseTimeConstant
        noiseFloor += Self.smoothingAlpha(delta: windowElapsed, tau: tau)
            * (target - noiseFloor)
        noiseFloor = max(noiseFloor, config.floorEpsilon)
        windowMin = 1
        windowElapsed = 0
    }

    private var enterThreshold: Float {
        max(noiseFloor * config.enterRatio, config.minSpeechLevel)
    }

    private var exitThreshold: Float {
        max(noiseFloor * config.exitRatio, config.minSpeechLevel * 0.5)
    }

    /// 与采样率无关的每帧 EMA 系数。
    private static func smoothingAlpha(delta: Double, tau: Double) -> Float {
        guard tau > 0 else { return 1 }
        return Float(1 - exp(-delta / tau))
    }

    // 诊断用（仅测试读取）。
    public var debugNoiseFloor: Float { noiseFloor }
    public var debugIsInSpeech: Bool { isInSpeech }
    public var debugCurrentSilence: Double { currentSilence }

    /// 全新会话（起停一次录音）用。连学到的噪声底一起清掉，下次从头学。
    public mutating func reset() {
        resetSegment()
        noiseFloor = 0
        isInSpeech = false
        floorInitialized = false
        windowMin = 1
        windowElapsed = 0
        aboveEnter = 0
        speechPeak = 0
    }

    /// 只重置本段计时（切段后、手动切段后）。噪声底与语音迟滞保留。
    public mutating func resetSegment() {
        speechAccumulated = 0
        currentSilence = 0
    }
}
