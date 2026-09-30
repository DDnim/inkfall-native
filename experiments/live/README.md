# 边听边插话（两个人聊天时即时纠错）

助手模式（⌥, 切过去）按 ⌥Space 开始长录音。两个人聊天，谁说错了明显的事实（「苹果是一种蔬菜」），
说完后 1 秒上下刘海出纠正并念出来。只纠错：两人之间的提问、「你帮我看看」是说给对方的，不答也不建卡。

## 管线（`App/Pipeline/LiveInterjector.swift`，记账在 InkfallCore `LiveUtteranceTracker`）

```
麦克风 ─ SilenceSegmenter（30 Hz 电平）
  停顿 0.2 秒 ─ Smart Turn v3.2（本机 CoreML，~3 ms，听语调）
      没说完 → 接着听，不转写；静音每长 0.2 秒再问一次；到 0.6 秒还没人开口 → 照常转写（兜底）
      说完了 → 这句开头到现在的音频 → Groq Whisper → 丢语气词 → Jev「结尾是不是说完了」≥ 0.6
          说完了 → 在这张票的位置切音频，收下这句 → Jev claim ≥ 0.5 → Groq Qwen 核对 → InterjectionPolicy → 刘海 + 念
          没说完 → 接着攒，下次停顿把攒下的整段再转写
  停顿 1.5 秒 ─ 不管说没说完都收
```

- 两边（Smart Turn 和 Jev）都说完才收下；Smart Turn 没好（第一次下载 17 MB 权重、载入 0.7 秒）时只靠 Jev
- Groq 免费档 Whisper 每分钟 20 次：试探至少给收尾留 4 次（`RequestBudget`），429 按服务端给的秒数停
- 念纠正前把已经说的话切走，念的期间录到的整段扔掉（那是 AI 自己的声音）
- 开关：`defaults write <bundle id> inkfall.liveSmartTurn -bool NO`（只靠 Jev）/ `inkfall.liveTurnGiveUp <秒>` / `inkfall.liveWhisperRPM <次>`

## 离线跑

```sh
python3 experiments/live/make_audio.py                 # macOS say 合成（快，但语调不像人，Smart Turn 判不准）
<装了 mlx-audio 的 python> experiments/live/make_audio_qwen.py   # Qwen3-TTS 整句合成（推荐）
python3 experiments/live/run.py d1 d2 d3 --gap 45 [--no-smart-turn] [--turn-give-up 秒]
```

`run.py` 起 App 的 `--live-sim <wav> --mute`：wav 按真实时间当麦克风放，Smart Turn / 转写 / Jev / 核对都是真的，
只有念纠正是按字数估时长（不出声）。对照 `audio/<名>.json` 的真值打分：

- 命中：该纠正的句子，在它之后两句之内出了纠正，且纠正里有期望的词；弱命中：出了纠正但没说出答案（「地球不是最大的行星」）或听错了
- 延迟：这句最后一个字 → 纠正出现
- 误插：不在任何该纠正句子窗口里的纠正

对话在 `dialogues.py`（d1/d2 该纠正的多，d3 陷阱多：观点、提问、转述、当场改口，d4 专测停一下才改口）。

## Smart Turn 为什么要用 Qwen3-TTS 的音频测

同一句话，Smart Turn 在 `say` 合成音上把说完的句尾判成没说完（「人一共有三百颗牙齿」0.03、「一年有十三个月」0.08），
换成真人录音（本人朗读 3 段）句尾都 ≥ 0.6，「一开始……」「最初は……」这种没说完的停顿 ≤ 0.07。
`make_audio_qwen.py` 把片段用逗号接成一句整句合成，再用强制对齐在片段之间补停顿，句中停顿前的语调是「还没完」的样子。

## 结果（2026-10-01，Qwen3-TTS 音频，d1–d4 共 9 处该纠正，`results.json` / `results.no-smart-turn.json`）

| 配置 | 命中 | 弱命中 | 误插 | 说完 → 纠正 p50 / max | 转写次数 |
|---|---|---|---|---|---|
| Smart Turn + Jev（默认） | 8/9 | 1 | 0 | 1.12 s / 1.57 s | 58 |
| 只靠 Jev（`--no-smart-turn`） | 8/9 | 1 | 0 | 1.06 s / 1.34 s | 59 |

- 弱命中那处是 Whisper 把「三百颗」听成「三百克」，纠正（「人没有300克牙齿」）照样及时出了
- 当场改口（d4，句号收尾、停 0.4 秒才说「啊不对」）：两次都先听了接着说的再放弃，没插
- 合成对话里两种配置分不出高下：句中犹豫少，Smart Turn 省下的转写被「短回话也要单独转写」
  （有 Smart Turn 时停顿门槛从 0.6 秒说话放宽到 0.3 秒）抵掉了。它的用处要看真人说话
- 各段耗时 p50：Whisper 330–460 ms、Jev ~170 ms、Qwen 核对 240–330 ms、Smart Turn 3 ms

迭代里修掉的（每条都是模拟里真出过的）：
- 两个人的话并成一段、里面带问句 → 按「提问」没核对（`Gate.liveRoute`：边听只纠错，有断言就核对）
- Whisper 句尾补逗号（「一年有13个月,」）→ Jev 判没说完（`dropTrailingComma`）
- 「日本的首都是大阪吧？」Jev claim 0.27（门的问法补了「讨附和的断言也算」→ 0.67）
- 纠正只说「地球不是最大的行星」（核对提示词：说出正确答案）
- Qwen 默认温度下同一句三次有一次判「正确」（核对 temperature 0）；漏引号的 JSON（按字段捞）
- 核对 2 秒才回来，本人早已改口（判插不插时带上这句之后已经收下的话）；Whisper 吐繁体「不對」（改口词表补繁体）
- 收尾那次 Jev 超时整句丢掉（收尾时 Jev 失败就不看门槛直接核对）
