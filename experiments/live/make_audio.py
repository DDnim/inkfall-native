"""把 dialogues.py 的对话用 macOS `say` 合成成一段 16 kHz 单声道 wav + 真值时间表 JSON。

    python3 experiments/live/make_audio.py [d1 d2 ...]   # 输出到 experiments/live/audio/（不进 git）

底噪 ≈ -50 dBFS（安静房间），开头 1 秒静音。只用标准库。
"""
import json, os, random, struct, subprocess, sys, tempfile, wave
from dialogues import DIALOGUES, VOICES

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "audio")
RATE = 16000
NOISE = 80  # ±80 / 32768 的均匀噪声 ≈ -52 dBFS RMS


def synth(text, voice):
    name, rate = voice
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "x.wav")
        subprocess.run(["say", "-v", name, "-r", str(rate), "-o", path, "--file-format=WAVE",
                        f"--data-format=LEI16@{RATE}", text], check=True)
        with wave.open(path) as w:
            frames = w.readframes(w.getnframes())
    samples = list(struct.unpack(f"<{len(frames)//2}h", frames))
    # say 的首尾有几十毫秒静音，按阈值裁掉，句中停顿由我们自己控制
    loud = [i for i, s in enumerate(samples) if abs(s) > 300]
    return samples[loud[0]:loud[-1] + 1] if loud else samples


def build(name):
    rng = random.Random(name)
    audio = [0] * RATE  # 开头 1 秒
    turns = []
    for speaker, pieces, gap, expect in DIALOGUES[name]:
        start = len(audio) / RATE
        text = ""
        for piece, pause in pieces:
            audio += synth(piece, VOICES[speaker])
            text += piece
            audio += [0] * int(pause * RATE)
        end = len(audio) / RATE
        turns.append({"speaker": speaker, "text": text, "start": round(start, 3), "end": round(end, 3),
                      "pieces": [p for p, _ in pieces], "expect": expect})
        audio += [0] * int(gap * RATE)
    audio = [max(-32768, min(32767, s + rng.randint(-NOISE, NOISE))) for s in audio]
    os.makedirs(OUT, exist_ok=True)
    with wave.open(os.path.join(OUT, f"{name}.wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(struct.pack(f"<{len(audio)}h", *audio))
    with open(os.path.join(OUT, f"{name}.json"), "w") as f:
        json.dump({"duration": len(audio) / RATE, "turns": turns}, f, ensure_ascii=False, indent=1)
    print(f"{name}: {len(audio)/RATE:.1f}s, {len(turns)} 句")


if __name__ == "__main__":
    for name in sys.argv[1:] or DIALOGUES:
        build(name)
