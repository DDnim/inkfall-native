"""跑边听边插话的模拟并打分。

    python3 experiments/live/make_audio.py            # 先合成对话（一次就行）
    python3 experiments/live/run.py [d1 d2 ...] [--app <Inkfall 可执行文件>] [--gap 60] [--no-smart-turn] [--turn-give-up 秒]

每段对话：App `--live-sim <wav> --mute --out <jsonl>`（wav 按真实时间放进去，转写 / Jev / 核对都是真的），
然后对照 audio/<名>.json 的真值：
- 该纠正的句子：有没有纠正、纠正里有没有期望的词、**说完 → 纠正出现**的延迟
- 误插：不对应任何该纠正句子的纠正
- 转写次数、因预算没试探的次数、半句被收下的次数
结果写到 out/<名>.jsonl（事件）和 results.json（汇总）。Groq 免费档每分钟 20 次转写，两段之间默认隔 60 秒。
"""
import json, os, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
APP = os.path.join(ROOT, "build/DerivedData/Build/Products/Debug/Inkfall.app/Contents/MacOS/Inkfall")


def tag(extra):
    return "".join("." + a.lstrip("-") for a in extra)


def run_one(name, app, extra):
    wav = os.path.join(HERE, "audio", f"{name}.wav")
    out = os.path.join(HERE, "out", f"{name}{tag(extra)}.jsonl")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run([app, "--live-sim", wav, "--mute", "--out", out] + extra, check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
    return [json.loads(line) for line in open(out)]


# Whisper 有时吐繁体，Qwen 跟着用繁体纠正（「日本的首都是東京」）：比期望词之前折成简体
TRAD = str.maketrans("東騰顆齒個陽與歲兩們對說過還陸這時氣來會長發這裡為", "东腾颗齿个阳与岁两们对说过还陆这时气来会长发这里为")


def score(name, events):
    truth = json.load(open(os.path.join(HERE, "audio", f"{name}.json")))["turns"]
    presents = [e for e in events if e["ev"] == "present"]
    acts = [e for e in events if e["ev"] == "act"]
    commits = [e for e in events if e["ev"] == "commit"]
    used = set()
    rows = []
    for i, turn in enumerate(truth):
        if not turn["expect"]:
            continue
        # 这句开始之后、后面第二句开始之前的纠正
        # 抢话时纠正会排队（念完上一句才念，最多等 8 秒）：一口气一串错话时，纠正可能落在两句之后
        horizon = max(truth[i + 2]["start"] if i + 2 < len(truth) else 1e9, turn["end"] + 8)
        window = [(k, p) for k, p in enumerate(presents) if k not in used and turn["start"] < p["t"] < horizon]
        # 纠正里有期望的词 = 命中；在这句的时间窗里纠正了、但没说出答案（「地球不是最大的行星」）或听错了 = 弱命中
        hit = next(((k, p) for k, p in window if any(w in p["text"].translate(TRAD) for w in turn["expect"])), None)
        weak = None if hit else next(iter(window), None)
        for found in (hit, weak):
            if found:
                used.add(found[0])
        found = hit or weak
        rows.append({"text": turn["text"], "hit": bool(hit), "weak": bool(weak),
                     "latency": round(found[1]["t"] - turn["end"], 2) if found else None,
                     "correction": found[1]["text"] if found else None})
    false = [p["text"] for k, p in enumerate(presents) if k not in used]
    # 半句被收下：收下的文字比它所在的那句短（按时间找句子）
    partial = []
    for c in commits:
        turn = max((t for t in truth if t["start"] <= c["t"]), key=lambda t: t["start"], default=None)
        if turn and len(c["text"].strip("，。？！,.?! ")) + 2 < len(turn["text"]) and not turn["text"].startswith(c["text"][:0]):
            partial.append({"commit": c["text"], "turn": turn["text"]})
    whisper = [e for e in events if e["ev"] == "whisper"]
    return {
        "dialogue": name,
        "hits": sum(r["hit"] for r in rows), "weak": sum(r["weak"] for r in rows), "expected": len(rows),
        "false": false,
        "latency": [r["latency"] for r in rows if r["hit"]],
        "rows": rows,
        "whisper_calls": len(whisper),
        "whisper_ms_p50": statistics.median([e["ms"] for e in whisper]) if whisper else None,
        "jev_ms_p50": statistics.median([e["ms"] for e in events if e["ev"] == "jev"] or [0]),
        "check_ms_p50": statistics.median([e["ms"] for e in acts if e.get("route") == "check"] or [0]),
        "budget_skips": sum(1 for e in events if e["ev"] == "pause-skip" and e.get("why") == "budget"),
        # Smart Turn 判没说完、省下的试探（同一段静音里反复问只算一次）
        "turn_not_done": sum(1 for k, e in enumerate(events) if e["ev"] == "turn" and not e["done"]
                             and not (k and events[k - 1]["ev"] == "turn")),
        "holds": sum(1 for e in events if e["ev"] == "hold"),
        "barge_ins": sum(1 for e in events if e["ev"] == "barge-in"),
        "hold_drops": [e["heard"] for e in events if e["ev"] == "hold-drop"],
        "partial_commits": partial,
        "commits": [c["text"] for c in commits],
    }


def main():
    args = sys.argv[1:]
    app = APP
    gap = 60
    if "--app" in args:
        app = args[args.index("--app") + 1]
        del args[args.index("--app"):args.index("--app") + 2]
    if "--gap" in args:
        gap = float(args[args.index("--gap") + 1])
        del args[args.index("--gap"):args.index("--gap") + 2]
    extra = []
    if "--no-smart-turn" in args:
        extra.append(args.pop(args.index("--no-smart-turn")))
    if "--no-barge-in" in args:
        extra.append(args.pop(args.index("--no-barge-in")))
    if "--turn-give-up" in args:
        k = args.index("--turn-give-up")
        extra += args[k:k + 2]
        del args[k:k + 2]
    names = args or ["d1", "d2"]
    results = []
    for k, name in enumerate(names):
        if k:
            time.sleep(gap)
        r = score(name, run_one(name, app, extra))
        results.append(r)
        print(f"{name}: 纠正 {r['hits']}/{r['expected']}（弱 {r['weak']}）  误插 {len(r['false'])} {r['false']}  "
              f"延迟 {r['latency']}  转写 {r['whisper_calls']} 次 p50 {r['whisper_ms_p50']}ms  "
              f"Jev p50 {r['jev_ms_p50']}ms  核对 p50 {r['check_ms_p50']}ms  预算跳过 {r['budget_skips']}  "
              f"SmartTurn 判没说完 {r['turn_not_done']}  先听接着说 {r['holds']} 次（改口不插 {r['hold_drops']}）")
        for row in r["rows"]:
            print(f"   {'✓' if row['hit'] else '△' if row['weak'] else '✗'} {row['text']} → {row['correction']} ({row['latency']}s)")
        for p in r["partial_commits"]:
            print(f"   半句：{p['commit']}  ⊂ {p['turn']}")
    lat = [x for r in results for x in r["latency"]]
    if lat:
        print(f"合计 纠正 {sum(r['hits'] for r in results)}/{sum(r['expected'] for r in results)}"
              f"（弱 {sum(r['weak'] for r in results)}）  "
              f"误插 {sum(len(r['false']) for r in results)}  延迟 p50 {statistics.median(lat):.2f}s max {max(lat):.2f}s")
    json.dump(results, open(os.path.join(HERE, f"results{tag(extra)}.json"), "w"),
              ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
