"""Jev 的「说完了吗」在 0.2 秒停顿时的门槛（边听边插话）。

    python3 experiments/live/jev_complete.py [v1 v2 v3]

用例：聊天里停顿 0.2 秒时的转写（真实 ASR 风格：有时带标点、繁体、错字）。
gold = True：这里收下是对的（一个完整的意思，对方可以接话了）；False：句子还没完（切了会把主语和谓语拆开）。
导语（「你知道吗」「我跟你说」「对了」）算没完：说话人马上要说正事。
"""
import json, os, statistics, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "jev"))
KEY = os.environ.get("TYPESAFE_API_KEY") or open(os.path.expanduser("~/.config/typesafe/api_key")).read().strip()

VARIANTS = {}
VARIANTS["v1"] = ("A listening assistant transcribes a live conversation and the speaker just paused briefly (about 0.2 seconds). `segment` "
          "is what they have said since the last cut (`previous` is earlier context). Is `segment` a complete thought — rather than "
          "the speaker pausing mid-sentence and about to continue the same sentence?")
# v2：问「结尾」—— 两个人你一句我一句、停顿都不到 1.5 秒时，攒下来的是好几句话（可能两个人的），
# 整段当然不是「一个完整的意思」，v1 就一直说没完（d1 攒了 40 秒一句也没收）。
VARIANTS["v2"] = ("A listening assistant transcribes a live conversation between people and the speaker just paused briefly "
                  "(about 0.2 seconds). `segment` is everything said since the last cut — it may hold several sentences, possibly "
                  "from different people (`previous` is earlier context). Does `segment` end with a finished sentence or thought — "
                  "rather than breaking off mid-sentence, with the speaker about to continue that sentence?")
VARIANTS["v3"] = ("Live conversation transcript. The current speaker just paused for about 0.2 seconds. `segment` is the "
                  "untranscribed-so-far stretch of talk (it can contain several sentences and more than one speaker). Look only at "
                  "how `segment` ends: is its last sentence finished, so a listener could respond now — rather than cut off in the "
                  "middle (a subject without its predicate, a lead-in like \"you know what\", a dangling conjunction)?")
LIVE_Q = VARIANTS["v2"]  # 采用（InterjectionAPI.liveCompleteQuestion），门槛 0.6

CASES = [
    # (previous, segment, gold)
    ("", "苹果其实是一种蔬菜", True),
    ("", "你知道吗苹果其实是一种蔬菜", True),
    ("", "水到五十度就会沸腾", True),
    ("", "日本的首都是大阪吧", True),
    ("", "对了，日本的首都是大阪吧", True),
    ("", "一年有十三个月", True),
    ("", "地球是太阳系里最大的行星", True),
    ("", "我觉得大阪比东京好玩", True),
    ("", "我们下周末一起去爬山吧", True),
    ("", "我昨天在超市买了好多，准备做沙拉", True),
    ("你买香蕉了吗", "买了，香蕉里钾挺多的，对身体好", True),
    ("", "我同事说长城在太空上用肉眼能看到", True),
    ("", "今天好热啊", True),
    ("", "你周末有什么安排", True),
    ("", "那你买香蕉了吗", True),
    ("", "真的假的，我一直以为是水果", True),
    ("", "月亮是自己发光的", True),
    ("", "人一共有三百颗牙齿", True),
    ("", "我打算去看电影然后吃个火锅", True),
    ("", "你开玩笑吧", True),
    ("", "我觉得你说的不太对", True),
    ("", "蘋果其實是一種蔬菜", True),
    ("", "是啊，夏天就是这样", True),
    ("", "东京塔有三百三十三米高", True),
    ("", "鲸鱼是鱼", True),
    # --- 没说完 ---
    ("", "你知道吗", False),
    ("", "我跟你说", False),
    ("", "对了，日本的首都", False),
    ("", "对了", False),
    ("", "日本的首都", False),
    ("", "我昨天在超市买了好多", False),
    ("", "人一共有", False),
    ("", "我跟你说人一共有", False),
    ("", "苹果其实是", False),
    ("", "水到", False),
    ("", "我觉得这个方案的问题在于", False),
    ("", "因为上周的数据显示", False),
    ("", "我打算去看电影", False),
    ("", "所以", False),
    ("", "然后我们", False),
    ("", "如果明天下雨的话", False),
    ("", "那个，就是说", False),
    ("", "我同事说", False),
    ("", "月亮是", False),
    ("", "今天好热啊估计有", False),
    ("", "地球是太阳系里", False),
    ("", "對了,這關在首都", False),
    ("", "你知道嗎?", False),
    # --- 攒成一大段（两个人你一句我一句）：看结尾 ---
    ("", "诶，我跟你说个事儿什么事？你知道吗，苹果其实是一种蔬菜", True),
    ("", "诶，我跟你说个事儿什么事？你知道吗", False),
    ("", "诶，我跟你说个事儿什么事", True),
    ("", "你知道吗，苹果其实是一种蔬菜真的假的，我一直以为是水果", True),
    ("", "你知道吗，苹果其实是一种蔬菜真的假的，我一直以为是水果我昨天在超市买了好多", False),
    ("", "我昨天在超市买了好多，准备做沙拉那你买香蕉了吗", True),
    ("", "买了，香蕉里钾挺多的，对身体好对了，日本的首都", False),
    ("", "买了，香蕉里钾挺多的，对身体好对了，日本的首都，是大阪吧", True),
    ("", "我觉得大阪比东京好玩嗯我同事说", False),
    ("", "我觉得大阪比东京好玩嗯我同事说长城在太空上用肉眼能看到", True),
    ("", "然后吃个火锅一年有13个月", True),
    ("", "然后吃个火锅一年有13个月好的好的月亮是自己发光的", True),
    ("", "今天好热啊估计有35度是啊，夏天就是这样我跟你说，人一共有", False),
    ("", "今天好热啊估计有35度是啊，夏天就是这样我跟你说，人一共有300颗牙齿", True),
    ("", "中国的首都是北京你周末有什么安排？我打算去看电影", True),
    ("", "中国的首都是北京你周末有什么安排？我打算去看电影然后", False),
]


def ask(previous, segment, question=None):
    body = json.dumps({"model": "jev-latest", "state": {"previous": previous, "segment": segment},
                       "questions": {"complete": {"type": "noul", "instructions": question or LIVE_Q}}}).encode()
    req = urllib.request.Request("https://api.typesafe.ai/v1/systemone", body,
                                 {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)["answers"]["complete"]["noul"]
        except Exception:
            if attempt == 2: raise
            time.sleep(1)


def main():
    names = sys.argv[1:] or ["v2"]
    for name in names:
        evaluate(name)


def evaluate(name):
    print(f"===== {name}")
    with ThreadPoolExecutor(6) as pool:
        ps = list(pool.map(lambda c: ask(c[0], c[1], VARIANTS[name]), CASES))
    rows = [{"segment": c[1], "gold": c[2], "p": round(p, 2)} for c, p in zip(CASES, ps)]
    for r in sorted(rows, key=lambda r: r["p"]):
        print(f"{r['p']:.2f} {'完' if r['gold'] else '半'} {r['segment']}")
    for th in [0.3, 0.4, 0.45, 0.5, 0.55, 0.6]:
        early = sum(1 for r in rows if not r["gold"] and r["p"] >= th)
        late = sum(1 for r in rows if r["gold"] and r["p"] < th)
        print(f"门槛 {th}: 半句被收 {early} / 说完了没收（等到 1.5 秒）{late}")
    json.dump(rows, open(os.path.join(os.path.dirname(__file__), f"jev_complete_{name}.json"), "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
