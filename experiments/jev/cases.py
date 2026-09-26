"""Jev 实验用例（手写，标签是境的判断标准的近似）。

SEG: 停顿 ~1.3 秒时，SilenceSegmenter 切下来的一段转写（末尾不带句号 —— 真实 ASR
     有时补句号有时不补，另跑一组「全部补 。」看 Jev 会不会被标点带偏）。
     complete=True  → 这里切是对的（一个完整的意思说完了）
     complete=False → 说话人只是在想词，切了会把一句话劈成两段
INTENT: 一段转写是不是在叫语音助手（Claude Code）干活，而不是在口述要打出来的正文。
     app 是当时的前台应用 —— 同一句话在 Slack 里是给同事的，在终端里是给助手的。
"""

SEG = [
    # --- 完整 ---
    ("zh", "", "明天下午三点开会，记得把上周的数据带上", True),
    ("zh", "", "这个方案我觉得可以直接上线", True),
    ("zh", "", "帮我把这段话改得正式一点", True),
    ("zh", "我们先看一下上个月的数据。", "整体来说转化率涨了百分之五", True),
    ("zh", "", "好的没问题", True),
    ("zh", "", "为什么这个接口每次都超时呢", True),
    ("zh", "", "第一点是性能，第二点是稳定性，第三点是成本", True),
    ("ja", "", "明日の会議は十時からに変更になりました", True),
    ("ja", "", "この件については来週改めて相談させてください", True),
    ("ja", "", "了解です", True),
    ("en", "", "Let's ship this on Friday", True),
    ("en", "", "I think the bug is in the retry logic", True),
    ("zh", "", "我今天用 Claude Code 重构了半个项目效果还不错", True),
    ("zh", "", "如果明天下雨的话我们就改到线上开", True),
    # --- 不完整（停下来想词） ---
    ("zh", "", "我觉得这个方案的问题在于", False),
    ("zh", "", "然后我们", False),
    ("zh", "", "因为上周的数据显示", False),
    ("zh", "", "这个功能主要是给那些", False),
    ("zh", "", "嗯就是说", False),
    ("zh", "", "第一点是性能，第二点是", False),
    ("zh", "", "如果明天下雨的话", False),
    ("zh", "", "我想跟你确认一下关于", False),
    ("zh", "我们先看一下上个月的数据。", "整体来说转化率", False),
    ("zh", "", "所以", False),
    ("ja", "", "明日の会議なんですが", False),
    ("ja", "", "この件については", False),
    ("ja", "", "えっと、それで", False),
    ("en", "", "I think the bug is in the", False),
    ("en", "", "Let's ship this on Friday but", False),
    ("en", "", "So the reason we", False),
]

# (app, text, is_assistant_call)
INTENT = [
    # --- 叫助手：带唤醒词 ---
    ("Terminal", "Claude，帮我把这个函数重构一下", True),
    ("VS Code", "嘿 Claude，跑一下测试看看有没有挂", True),
    ("Notes", "Claude 帮我把刚才那段翻译成日语", True),
    ("Terminal", "クロード、このブランチのテストを回して", True),
    ("VS Code", "Hey Claude, open a PR for this branch", True),
    ("Notes", "今天会议的要点如下，第一预算不变，第二下周上线。Claude，帮我把这段整理成要点", True),
    # --- 叫助手：没有唤醒词 ---
    ("Terminal", "帮我看一下为什么构建失败了", True),
    ("VS Code", "把这个文件里所有的 print 都删掉", True),
    ("Notes", "把刚才那段改得正式一点", True),
    ("Terminal", "查一下这个仓库最近一周谁提交最多", True),
    ("Safari", "总结一下这个网页讲了什么", True),
    ("VS Code", "run the tests and tell me what failed", True),
    # --- 口述正文：提到 Claude 但不是在叫它 ---
    ("Notes", "我昨天用 Claude Code 重构了半个项目，效果还不错", False),
    ("Slack", "Claude 这个名字挺好听的", False),
    ("Notes", "I told Claude to open a PR but it failed", False),
    ("Slack", "你们有人试过让 Claude 自动跑测试吗", False),
    # --- 口述正文：祈使句但对象是人 ---
    ("Slack", "请大家在周五之前把周报发给我", False),
    ("Slack", "你帮我看一下这个 PR 有没有问题", False),
    ("Mail", "田中さん、お疲れ様です。明日の会議の資料を送ります", False),
    ("Mail", "Please review the attached contract and let me know by Monday", False),
    ("Notes", "明天记得买牛奶和鸡蛋", False),
    # --- 口述正文：普通内容 ---
    ("Notes", "这个方案的核心是把转写和加工拆成两步", False),
    ("Notes", "整体来说转化率涨了百分之五", False),
    ("Slack", "好的没问题，我下午处理", False),
    ("Notes", "今日は天気がいいので散歩に行きました", False),
    # --- 同一句话，换前台应用 ---
    ("Slack", "帮我看一下为什么构建失败了", False),
    ("Terminal", "你帮我看一下这个 PR 有没有问题", True),
]

KEYWORDS = ["claude", "克劳德", "クロード", "贾维斯", "jarvis"]  # 旧贾维斯的做法：扫关键词

# --- 难例：第一轮 SEG/INTENT 全部分得很开（见 README），补一组边界上的 ---
SEG_HARD = [
    ("zh", "", "对", True),
    ("zh", "", "行吧明天再说", True),
    ("zh", "", "这个我不同意", True),
    ("zh", "", "有三个问题需要讨论", True),
    ("ja", "", "そうですね", True),
    ("en", "", "git push origin main", True),
    ("zh", "", "他说", False),
    ("zh", "", "我昨天看到那个", False),
    ("zh", "", "不是因为贵而是", False),
    ("zh", "", "这个 bug 其实是", False),
    ("zh", "", "有三个问题，第一个", False),
    ("ja", "", "それはつまり", False),
    ("en", "", "The main reason is", False),
]

INTENT_HARD = [
    ("Terminal", "修复登录页在 iPad 上布局错乱的问题", False),   # 在终端里口述 commit message
    ("Notes", "给 Claude 的提示词写成：请帮我把这个函数重构一下", False),
    ("Slack", "Claude 说测试都过了", False),
    ("Notes", "Claude 你觉得这个方案怎么样", True),
    ("Mail", "翻译成英文：我明天请假", True),
    ("Notes", "等一下，把上一句删掉", True),
    ("Notes", "帮我记一下，下周试试 Jev", False),              # 口语的「帮我记一下」后面是正文
]

# --- 验证集：写 app_kind 提问之后才补的新句子，用来查是不是只记住了上面的错例 ---
INTENT_FRESH = [
    ("Slack", "麻烦把昨天的会议纪要发一下", False),
    ("Slack", "能不能帮我 review 一下这个改动", False),
    ("Mail", "请查收附件中的报价单", False),
    ("Terminal", "把 node_modules 删了重新装一遍", True),
    ("Terminal", "看看是哪个进程占了 3000 端口", True),
    ("VS Code", "给这个函数补个单元测试", True),
    ("VS Code", "这个函数负责解析用户输入的日期", False),   # 口述注释
    ("Notes", "帮我把上面三段合成一段", True),
    ("Notes", "周三要跟设计确认首页的配色", False),
    ("Slack", "Claude，把这个频道今天的讨论总结一下", True),
    ("Mail", "Claude 帮我把这封邮件改得客气一点", True),
    ("Slack", "我让 Claude 跑了一下，结果没问题", False),
    ("Safari", "这个页面的价格是多少", True),
    ("Notes", "今天学到的：Jev 不看前台应用", False),
]
