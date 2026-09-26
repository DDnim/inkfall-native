"""用 Jev 测两件事：① 停顿处该不该切段 ② 这段话是不是在叫语音助手。

    TYPESAFE_API_KEY=... python3 experiments/jev/run.py   # 或把 key 放在 ~/.config/typesafe/api_key
结果写到 experiments/jev/results.json，汇总打到 stdout。只用标准库。
"""
import json, os, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from cases import SEG, INTENT, SEG_HARD, INTENT_HARD, KEYWORDS

KEY = os.environ.get("TYPESAFE_API_KEY") or open(os.path.expanduser("~/.config/typesafe/api_key")).read().strip()
HERE = os.path.dirname(os.path.abspath(__file__))

SEG_Q = {
    "complete": {"type": "noul", "instructions":
        "A dictation app transcribes speech and the speaker just paused for about 1.3 seconds. `segment` is what they said "
        "since the last cut (`previous` is earlier context). Is `segment` a complete thought, so it is right to cut and send it "
        "now — rather than the speaker pausing mid-sentence to think and about to continue the same sentence?"},
}
INTENT_Q = {
    "assistant": {"type": "noul", "instructions":
        "The user speaks into a dictation app that normally types their words into `app`. They can also talk to a voice "
        "assistant (Claude Code) that performs tasks on their computer. Is `text` (or its last sentence) addressed to the "
        "assistant as a request to do something, rather than content the user wants typed out or a message to another person?"},
    "kind": {"type": "choice", "instructions": "What is `text`?", "criteria": {
        "dictation": "content the user wants typed into the app as-is (notes, messages to people, emails)",
        "assistant": "a request for the voice assistant to do something (edit, translate, run, look up, summarise)",
    }},
}


def ask(state, questions):
    body = json.dumps({"state": state, "model": "jev-latest", "questions": questions}).encode()
    req = urllib.request.Request("https://api.typesafe.ai/v1/systemone", body,
                                 {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    for attempt in range(3):
        try:
            t0 = time.time()
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)["answers"], round((time.time() - t0) * 1000)
        except Exception:
            if attempt == 2: raise
            time.sleep(2)


def seg_job(case, punct, hard=False):
    lang, prev, text, gold = case
    a, ms = ask({"language": lang, "previous": prev, "segment": text + ("。" if punct else "")}, SEG_Q)
    return {"lang": lang, "previous": prev, "segment": text, "punct": punct, "gold": gold, "hard": hard, "p": a["complete"]["noul"], "ms": ms}


def intent_job(case, hard=False):
    app, text, gold = case
    a, ms = ask({"app": app, "text": text}, INTENT_Q)
    return {"app": app, "text": text, "gold": gold, "hard": hard, "p": a["assistant"]["noul"], "kind": a["kind"]["choice"],
            "kw": any(k in text.lower() for k in KEYWORDS), "ms": ms}


def summary(name, rows, pred, prob=lambda r: r["p"]):
    ok = [r for r in rows if pred(r) == r["gold"]]
    fp =sum(pred(r) and not r["gold"] for r in rows)
    fn = sum(not pred(r) and r["gold"] for r in rows)
    brier = sum((prob(r) - r["gold"]) ** 2 for r in rows) / len(rows)
    print(f"  {name:28} acc {len(ok)}/{len(rows)}  FP {fp}  FN {fn}  Brier {brier:.3f}")


with ThreadPoolExecutor(6) as ex:
    seg = list(ex.map(lambda a: seg_job(*a), [(c, p, False) for p in (False, True) for c in SEG]
                                              + [(c, False, True) for c in SEG_HARD]))
    intent = list(ex.map(lambda a: intent_job(*a), [(c, False) for c in INTENT] + [(c, True) for c in INTENT_HARD]))

json.dump({"seg": seg, "intent": intent}, open(f"{HERE}/results.json", "w"), ensure_ascii=False, indent=1)

print("① 断句（complete ≥ 0.5 → 切）")
for punct in (False, True):
    rows = [r for r in seg if r["punct"] == punct and not r["hard"]]
    summary("Jev 末尾无标点" if not punct else "Jev 末尾补。", rows, lambda r: r["p"] >= 0.5)
summary("Jev 难例", [r for r in seg if r["hard"]], lambda r: r["p"] >= 0.5)
summary("基线：停顿即切", [r for r in seg if not r["punct"] and not r["hard"]], lambda r: True, lambda r: 1.0)
for r in seg:
    if (r["p"] >= 0.5) != r["gold"]:
        print(f"    ✗ {'难' if r['hard'] else ' '}{'。' if r['punct'] else ' '} p={r['p']:.2f} gold={r['gold']!s:5} {r['segment']}")

print("\n② 叫助手（assistant ≥ 0.5）")
base = [r for r in intent if not r["hard"]]
summary("Jev noul", base, lambda r: r["p"] >= 0.5)
summary("Jev choice", base, lambda r: r["kind"] == "assistant")
summary("基线：关键词", base, lambda r: r["kw"], lambda r: float(r["kw"]))
summary("Jev noul 难例", [r for r in intent if r["hard"]], lambda r: r["p"] >= 0.5)
summary("基线：关键词 难例", [r for r in intent if r["hard"]], lambda r: r["kw"], lambda r: float(r["kw"]))
for r in intent:
    if (r["p"] >= 0.5) != r["gold"]:
        print(f"    ✗ {'难' if r['hard'] else ' '} p={r['p']:.2f} gold={r['gold']!s:5} [{r['app']}] {r['text']}")

ms = sorted(r["ms"] for r in seg + intent)
print(f"\nlatency p50 {ms[len(ms)//2]}ms  p90 {ms[int(len(ms)*.9)]}ms  n={len(ms)}")
