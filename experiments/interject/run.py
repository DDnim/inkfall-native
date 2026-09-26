"""插话纠错的离线评测：① Jev 单独判「说错了吗」 ② Jev 门 + 加工模型核对（App 的 --interject-eval，提示词与 App 同一份）。

    python3 experiments/interject/run.py [--providers=groq,openai,gemini] [--model=qwen/qwen3-32b] [--gated-only]
先构建 App（见 CLAUDE.md）。加工模型的 key 由 App 自己从钥匙串读；TypeSafe key 取 TYPESAFE_API_KEY
或 ~/.config/typesafe/api_key。结果写 experiments/interject/results.json。只用标准库。
"""
import json, os, subprocess, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from cases import GROUPS

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
APP = os.path.join(ROOT, "build/DerivedData/Build/Products/Debug/Inkfall.app/Contents/MacOS/Inkfall")
KEY = os.environ.get("TYPESAFE_API_KEY") or open(os.path.expanduser("~/.config/typesafe/api_key")).read().strip()

# verbatim：与 InterjectionAPI.claimQuestion 相同（门的第二问）
CLAIM_Q = ("`segment` is what a person just said aloud (`previous` is what they said just before). Does `segment` state, as the "
           "speaker's own claim, a fact about the world that could be checked against common knowledge — rather than an opinion, "
           "a plan, a question, an instruction, a joke, or words the speaker attributes to someone else?")
# 对照：Jev 单独判真假（不经过加工模型）
FALSE_Q = ("`segment` is what a person just said aloud (`previous` is context). Does `segment` contain the speaker's own factual "
           "claim that is clearly false by common knowledge, so a friend listening should politely correct them? Answer no for "
           "opinions, questions, jokes, quotes of other people, claims they already corrected themselves, and debatable claims.")
# CHECK_INSTRUCTIONS 在 App/InkfallCore 的 InterjectionAPI.checkInstructions（评测直接调 App，不在这里复制）

cases = [{"id": f"{g}-{i:02d}", "group": g, "previous": prev, "text": text, "gold": g == "wrong"}
         for g, items in GROUPS.items() for i, (prev, text) in enumerate(items)]


def jev(c):
    body = json.dumps({"model": "jev-latest", "state": {"previous": "\n".join(c["previous"]), "segment": c["text"]},
                       "questions": {"false": {"type": "noul", "instructions": FALSE_Q}}}).encode()
    req = urllib.request.Request("https://api.typesafe.ai/v1/systemone", body,
                                 {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    for attempt in range(3):
        try:
            t0 = time.time()
            with urllib.request.urlopen(req, timeout=60) as r:
                return {"id": c["id"], "p_false": json.load(r)["answers"]["false"]["noul"], "ms": round((time.time() - t0) * 1000)}
        except Exception:
            if attempt == 2: raise
            time.sleep(2)


def app_eval(provider, gate=True):
    src, out = os.path.join(HERE, "cases.json"), os.path.join(HERE, f"out-{provider}{'' if gate else '-nogate'}.json")
    json.dump([{k: c[k] for k in ("id", "previous", "text")} for c in cases], open(src, "w"), ensure_ascii=False)
    model = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--model=")), None)
    args = [APP, "--interject-eval", src, out, "--provider", provider, "--pace", "15"] + ([] if gate else ["--no-gate"]) \
        + (["--model", model] if model else [])
    p = subprocess.run(args, capture_output=True, text=True, timeout=900)
    if p.returncode != 0 or not os.path.exists(out):
        print(f"  {provider}: App 评测失败 {p.stdout[-300:]} {p.stderr[-300:]}")
        return None
    rows = {r["id"]: r for r in json.load(open(out))}
    failed = [r["id"] for r in rows.values() if r.get("stopped", "").startswith(("check-failed", "check-timeout", "gate-failed"))]
    if failed: print(f"  {provider}: {len(failed)} 条请求失败（限流？看 /tmp/inkfall-native.log）: {', '.join(failed)}")
    if not any(r.get("route") for r in rows.values()) and any(r.get("stopped") == "no-check-route" for r in rows.values()):
        print(f"  {provider}: 没有 key，跳过")
        return None
    return rows


def report(name, pred, rows=None):
    fp = [c for c in cases if pred(c) and not c["gold"]]
    fn = [c for c in cases if not pred(c) and c["gold"]]
    print(f"  {name:34} 误插 {len(fp):2}  漏插 {len(fn):2}/{sum(c['gold'] for c in cases)}"
          + (f"  误插: {', '.join(c['id'] for c in fp)}" if fp else ""))
    return {"name": name, "fp": [c["id"] for c in fp], "fn": [c["id"] for c in fn]}


providers = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--providers=")), "groq,openai,gemini").split(",")
with ThreadPoolExecutor(6) as ex:
    jev_rows = {r["id"]: r for r in ex.map(jev, cases)}
results = {"cases": cases, "jev": jev_rows, "apps": {}}
print(f"{len(cases)} 条（应插 {sum(c['gold'] for c in cases)}）")
summary = [report("Jev 单独 p_false ≥ 0.5", lambda c: jev_rows[c["id"]]["p_false"] >= 0.5),
           report("Jev 单独 p_false ≥ 0.7", lambda c: jev_rows[c["id"]]["p_false"] >= 0.7)]
for provider in providers:
    for gate in ((True,) if "--gated-only" in sys.argv else (True, False)):
        rows = app_eval(provider, gate)
        if rows is None: break
        results["apps"][f"{provider}{'' if gate else '-nogate'}"] = rows
        label = f"{'Jev 门 + ' if gate else '只用 '}{provider} {rows[cases[0]['id']].get('route') or next((r['route'] for r in rows.values() if r['route']), '')}"
        summary.append(report(label, lambda c, rows=rows: bool(rows[c["id"]].get("shown"))))
        ms = sorted(r["gate_ms"] + r["check_ms"] for r in rows.values() if r.get("check_ms"))
        if ms: print(f"  {'':34} 核对过的 {len(ms)} 条延迟 p50 {ms[len(ms)//2]}ms p90 {ms[int(len(ms)*.9)]}ms")
results["summary"] = summary
by_group = {}
for c in cases: by_group.setdefault(c["group"], []).append(c["id"])
json.dump(results, open(os.path.join(HERE, "results.json"), "w"), ensure_ascii=False, indent=1)
