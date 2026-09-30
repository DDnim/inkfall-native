"""把 dialogues.py 的对话用 Qwen3-TTS 合成（比 `say` 像真人说话），输出格式同 make_audio.py。

    <装了 mlx-audio 的 python> experiments/live/make_audio_qwen.py [d1 d2 ...]
    LIVE_REF_AUDIO=<参考录音.wav> LIVE_REF_TEXT=<它念的字> ...   # A 用克隆声（Qwen3-TTS Base）

为什么要它：Smart Turn 靠语调判「说完了没有」，`say` 的句尾语调不像人（「一年有十三个月」说完了它判 0.08），
测出来的是合成器的毛病。这里**整句一口气合成**（片段之间用逗号接，语调是「还没完」的样子），
再用强制对齐找到片段的边界，在那里把停顿补到 dialogues.py 写的长度 —— 句中停顿前的语调是自然的。

A 没给参考录音时用 CustomVoice 的 Dylan，B 用 Serena。合成结果按文字 + 声音缓存在 audio/qwen-cache/。
"""
import hashlib, json, os, random, subprocess, sys, tempfile

os.environ.setdefault("HF_HOME", os.path.expanduser("~/AI/moss-tts/models"))
os.environ["TOKENIZERS_PARALLELISM"] = "false"

import numpy as np
import soundfile as sf
from dialogues import DIALOGUES

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "audio")
CACHE = os.path.join(OUT, "qwen-cache")
RATE = 16000
NOISE = 80

BASE = ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit", "e7dd0585652209fa0d7783659aad4e8a324de11c")
CUSTOM = ("mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-6bit", "1c6c0ff58c43afa8df571facde2efa077efd85e2")
ALIGNER = ("mlx-community/Qwen3-ForcedAligner-0.6B-8bit", "0e1a68e91d815300c7c9754b2a7639378b23db15")
REF_AUDIO = os.environ.get("LIVE_REF_AUDIO")
REF_TEXT = os.environ.get("LIVE_REF_TEXT", "")
INSTRUCT = "像和朋友面对面聊天一样，自然随意，语速正常。"
VOICES = {"A": "Dylan", "B": "Serena"}
PUNCT = "，。！？、,.!?…"


def snapshot(repo, revision):
    from huggingface_hub import snapshot_download
    return snapshot_download(repo_id=repo, revision=revision)


def spoken(pieces):
    """片段接成一句：片段末尾没标点的补逗号（最后一段不补）。"""
    text = ""
    for k, piece in enumerate(pieces):
        text += piece
        if k < len(pieces) - 1 and piece[-1] not in PUNCT:
            text += "，"
    return text


def key(speaker, text):
    voice = f"clone:{hashlib.sha256(open(REF_AUDIO, 'rb').read()).hexdigest()[:12]}" if speaker == "A" and REF_AUDIO else VOICES[speaker]
    return hashlib.sha256(f"{voice}|{text}".encode()).hexdigest()[:16]


def synth_all(lines):
    """lines: [(speaker, text)] → 缓存里没有的都合成出来（24 kHz）。"""
    todo = [(s, t) for s, t in lines if not os.path.exists(os.path.join(CACHE, key(s, t) + ".wav"))]
    if not todo:
        return
    import mlx.core as mx
    from mlx_audio.tts import load
    os.makedirs(CACHE, exist_ok=True)
    for clone in (True, False):
        batch = [(s, t) for s, t in todo if bool(s == "A" and REF_AUDIO) == clone]
        if not batch:
            continue
        model = load(snapshot(*(BASE if clone else CUSTOM)))
        for n, (speaker, text) in enumerate(batch):
            # 偶尔会生成跑飞（「哈哈」出来 24 秒）：比字数该有的长太多就换个种子重来
            for attempt in range(4):
                mx.random.seed((int(key(speaker, text), 16) + attempt * 7919) % (2 ** 32))
                if clone:
                    chunks = model.generate(text=text, ref_audio=REF_AUDIO, ref_text=REF_TEXT, language="Chinese",
                                            temperature=0.7, max_tokens=600)
                else:
                    chunks = model.generate_custom_voice(text=text, speaker=VOICES[speaker], language="Chinese",
                                                         instruct=INSTRUCT, temperature=0.7, max_tokens=600)
                parts, rate = [], 24000
                for r in chunks:
                    parts.append(np.asarray(r.audio))
                    rate = r.sample_rate
                audio = np.concatenate(parts)
                if len(audio) / rate <= 1.5 + 0.4 * len(text):
                    break
                print(f"  跑飞了（{len(audio) / rate:.1f}s），重来：{text}", flush=True)
            sf.write(os.path.join(CACHE, key(speaker, text) + ".wav"), audio, rate)
            print(f"  合成 {n + 1}/{len(batch)} {speaker} {text} {len(audio) / rate:.1f}s", flush=True)
        del model


def align_all(items):
    """多片段的句子：强制对齐，得到每个字的起止（缓存成 .align.json）。"""
    todo = [(s, t) for s, t in items if not os.path.exists(os.path.join(CACHE, key(s, t) + ".align.json"))]
    if not todo:
        return
    from mlx_audio.stt import load
    model = load(snapshot(*ALIGNER))
    for speaker, text in todo:
        path = os.path.join(CACHE, key(speaker, text) + ".wav")
        spans = [{"text": x.text, "start": x.start_time, "end": x.end_time}
                 for x in model.generate(path, text=text, language="Chinese")]
        json.dump(spans, open(os.path.join(CACHE, key(speaker, text) + ".align.json"), "w"), ensure_ascii=False)


def load16k(path):
    """→ 16 kHz 单声道 float，首尾静音裁掉。"""
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "x.wav")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", path, "-ac", "1", "-ar", str(RATE), out], check=True)
        audio, _ = sf.read(out, dtype="float32")
    loud = np.nonzero(np.abs(audio) > 0.01)[0]
    return (audio[loud[0]:loud[-1] + 1], loud[0] / RATE) if len(loud) else (audio, 0.0)


def boundaries(spans, pieces, text):
    """每个片段边界（除最后一个）：前一片段最后一个字的结束、后一片段第一个字的开始（秒，相对合成音频）。"""
    chars = [(c, s["start"], s["end"]) for s in spans for c in s["text"] if c not in PUNCT and not c.isspace()]
    result, index = [], 0
    for piece in pieces[:-1]:
        index += len([c for c in piece if c not in PUNCT and not c.isspace()])
        if index <= 0 or index >= len(chars):
            return None
        result.append((chars[index - 1][2], chars[index][1]))
    return result


def build(name):
    rng = random.Random(name)
    lines = [(speaker, spoken([p for p, _ in pieces])) for speaker, pieces, _, _ in DIALOGUES[name]]
    synth_all(lines)
    align_all([line for line, (_, pieces, _, _) in zip(lines, DIALOGUES[name]) if len(pieces) > 1])

    audio = [np.zeros(RATE, dtype=np.float32)]
    at = 1.0
    turns = []
    for (speaker, text), (_, pieces, gap, expect) in zip(lines, DIALOGUES[name]):
        wave_, lead = load16k(os.path.join(CACHE, key(speaker, text) + ".wav"))
        if len(pieces) > 1:
            spans = json.load(open(os.path.join(CACHE, key(speaker, text) + ".align.json")))
            cuts = boundaries(spans, [p for p, _ in pieces], text)
            if cuts is None:
                print(f"  对齐不上，按整句用：{text}")
            else:
                # 在片段之间（自然停顿的中点）补静音，让停顿至少是 dialogues.py 写的长度
                segments, last = [], 0
                for (end, start), (_, pause) in zip(cuts, pieces):
                    middle = int(((end + start) / 2 - lead) * RATE)
                    natural = max(0.0, start - end)
                    segments.append(wave_[last:middle])
                    segments.append(np.zeros(int(max(0.0, pause - natural) * RATE), dtype=np.float32))
                    last = middle
                segments.append(wave_[last:])
                wave_ = np.concatenate(segments)
        start = at
        audio.append(wave_)
        at += len(wave_) / RATE
        turns.append({"speaker": speaker, "text": "".join(p for p, _ in pieces), "start": round(start, 3),
                      "end": round(at, 3), "pieces": [p for p, _ in pieces], "expect": expect})
        audio.append(np.zeros(int(gap * RATE), dtype=np.float32))
        at += gap
    pcm = np.concatenate(audio)
    pcm = pcm * (0.9 / max(1e-6, float(np.max(np.abs(pcm)))))
    samples = np.clip(np.round(pcm * 32767) + np.array([rng.randint(-NOISE, NOISE) for _ in range(len(pcm))]),
                      -32768, 32767).astype(np.int16)
    os.makedirs(OUT, exist_ok=True)
    sf.write(os.path.join(OUT, f"{name}.wav"), samples, RATE, subtype="PCM_16")
    json.dump({"duration": len(samples) / RATE, "turns": turns, "engine": "qwen3-tts"},
              open(os.path.join(OUT, f"{name}.json"), "w"), ensure_ascii=False, indent=1)
    print(f"{name}: {len(samples) / RATE:.1f}s, {len(turns)} 句")


if __name__ == "__main__":
    for name in sys.argv[1:] or DIALOGUES:
        build(name)
