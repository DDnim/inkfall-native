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

对话在 `dialogues.py`（d1/d2 该纠正的多，d3 陷阱多：观点、提问、转述、当场改口）。

## Smart Turn 为什么要用 Qwen3-TTS 的音频测

同一句话，Smart Turn 在 `say` 合成音上把说完的句尾判成没说完（「人一共有三百颗牙齿」0.03、「一年有十三个月」0.08），
换成真人录音（本人朗读 3 段）句尾都 ≥ 0.6，「一开始……」「最初は……」这种没说完的停顿 ≤ 0.07。
`make_audio_qwen.py` 把片段用逗号接成一句整句合成，再用强制对齐在片段之间补停顿，句中停顿前的语调是「还没完」的样子。

## 结果

见 `results*.json` 和 vault 的 `Wiki/inkfall-AI插话纠错设计.md` §8。
