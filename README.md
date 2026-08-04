# inkfall-native

落音 Inkfall 的 macOS 客户端 —— **原生 Swift / SwiftUI**。按住一个键说话，
文字落回你刚才那个窗口；说得久一点就落成笔记；说一句关键词，后台的
Claude Code 接着干活。**转写目前全在本机跑**（云端路径还没接），
推理运行时编译进二进制，不需要另外装 Python 环境。转写完的**加工**可以交给
云端 API（OpenAI / Groq / Gemini），也可以交给本机的 `claude -p`。

这个仓库是 `inkfall-app`（Tauri 2 / Rust + WebView）的重写，目标是取代它。
完整技术规格在 [`../inkfall-docs/spec/`](../inkfall-docs/spec/)（13 份）。

> **状态：重写进行中，还没有发布版。** 核心链路（听写 / 笔记 / 语音助手 /
> 本地集成 / AI 加工）已经能日常用，但云端**转写**、自动更新、本地化还没接。
> 现在要用只能自己构建，见 [构建](#构建)。

---

## 它能做什么

| 手势 | 做什么 |
|------|--------|
| **按住右 ⌥** | 按住说话。松开 → 本机转写 → 文字插回你说话前的那个窗口 |
| **双击右 ⌥ 并按住** | 问助手。问题连同你选中的文字交给 Claude Code，答案显示出来，**不粘贴** |
| **⌥Space** | 落笔：连续录音。说到停顿自动切段，按说话顺序落进笔记 |
| **⌥,** | 贾维斯待命：一直听着，只扫关键词，**不留任何文字** |
| **⌥.** / 右⌥ 单击 | 手动切段 / 把攒下的段一次粘出去 |
| **⌥;** / **⌥'** | 框选截图 / 整屏截图，直接插进当前笔记 |
| **⌥Esc** | 停止（在飞的段照常转写保存，绝不丢数据） |

**全篇转译**（笔记面板底部录音条，停止录音后出现）：把整篇的语音片段拼成一个 WAV，**跑一次**带
说话人分离的转写，结果另存为「原标题 · 全篇转译」。落笔是边录边切的，每段
各自跑一次分离 —— 第 1 段的「说话人 1」和第 3 段的「说话人 1」很可能不是
同一个人，而且每段往往只有一个人在说，于是**一个标签都不会出**。整篇跑一次，
聚类才是全篇范围的，人物关系才对得上。

三种模式**可以叠加**：贾维斯扫描是一个 filter，笔记是一个 sink，两者正交 ——
落笔录音时按 ⌥, 就是「每段既留下又扫描」。

> **语音命令与贾维斯默认是关的**（关键词可以触发任意 shell），
> 在 设置 → 语音命令 里开。「按住提问」默认开着。

**落笔**（⌥Space）录音时正文是**只读的 markdown 预览** —— 下一段随时会追加
进来，此刻可编辑只会把光标挤走；停下来才变成 markdown 编辑器。每段独立转写，
但按**说话顺序**落地（第 3 段先转完也得等第 2 段）。停下来时还在飞的段照常
转写补进正文。每次开始录音新建一篇，最多留 100 条。

### 语音助手（Claude Code）

说「克劳德，帮我看看这段」——后台 tmux 里跑一轮 `claude -p`，答案回到刘海、
全文进剪贴板。**同一个关键词的后续每一句都 `--resume` 接回同一场会话**，
所以它记得住上下文；`tmux attach -t inkfall` 能翻回每一轮的问与答。

```
第一轮   claude -p --session-id <uuid> --output-format json "…"
之后每轮 claude -p --resume     <uuid> --output-format json "…"
```

会话 id 是客户端自己生成并按上去的，不从输出里刨 —— 第一轮的回答还没写完，
就已经知道下一轮该接哪儿。

三道权限刻意分开，从窄到宽：

| 开关 | 默认 | 给了什么 |
|------|------|---------|
| 允许联网查资料 | **开** | `--allowed-tools WebSearch,WebFetch`，只读 |
| 跳过权限确认 | **关** | `--dangerously-skip-permissions`，能改文件、能跑命令 |
| 语音命令总开关 | **关** | 关键词可以触发**任意 shell**（终端命令那一路） |

> `claude -p` 是非交互的：需要确认的工具弹不出确认框会被**直接拒掉**，
> 模型只回一句「我没拿到权限」。所以联网默认放行 —— 否则「今天股价多少」
> 这类问题永远答不了，看起来像助手不能上网。

命中关键词后有 **3 秒撤销倒计时**：esc 撤销、↩ 立即执行。误触发一条 shell
命令的代价是不对称的，所以决策点放在**执行之前**。这两个键**只在**倒计时
期间被接管，其余时间原样透传给前台 App。

### 本地集成 API + MCP

`127.0.0.1:48765` 上有一套笔记读写 API，让编码助手能读写你的笔记：

```sh
claude mcp add inkfall -- node ~/Library/Application\ Support/app.inkfall.native/inkfall-mcp.mjs
```

MCP 桥内嵌在 App 里，每次启动重写到数据目录 —— 升级后磁盘上那份自动最新，
注册的路径不变。

**双重门禁**：设置里的开关必须开（否则 403），且 `Authorization: Bearer
<token>` 必须匹配（否则 401）。token 是 64 位十六进制、权限 `0600`，
监听只绑回环。另有一组 `/debug/*` 只读路由不需要 token（见下）。

---

### 加工：转写完再过一遍模型

九个预设（基础整理 / 轻度整理 / 清理口语 / 润色表达 / 简短总结 / 邮件 /
笔记 / 会议纪要 / 自定义），右 ⌥ + F1…F9 直接切。跑在哪儿有两条路：

| 引擎 | 要什么 | 备注 |
|------|--------|------|
| 云端 API | OpenAI / Groq / Gemini 的 key（存钥匙串） | Groq 的 `gpt-oss-20b` 又快又便宜，是默认 |
| Claude Code | 本机装了 `claude` 并且登录过 | 走 headless（`claude -p`），**流式**回来，**不需要额外的 key** |

**「基础整理」是纯本地规则**（去口头禅、补标点），不联网也不要 key。
录音短于 3 秒、不足 10 字、带说话人标签、或者根本没配 key 时，都会自动退回
它 —— **文字永远不会因为加工失败而丢**。鉴权与额度问题不降级，会明说
（静默重试只会掩盖一个用户必须处理的问题）。

> ⚠️ **Claude Code 那条路必须显式把上下文裁干净。** 裸的 `claude -p` 会把
> CLAUDE.md、skills、hooks、MCP、全套工具定义加载一遍 —— 本机实测一次两行的
> 口语清理吃掉 **19 982 个 cache-creation token、$0.2006**。
> 加上 `--tools "" --disable-slash-commands --strict-mcp-config
> --setting-sources ""` 之后是 **256 个 input token、$0.0027**。
>
> 用这几个开关而**不用 `--bare`**：bare 会连 OAuth 一起跳过（反而要
> `ANTHROPIC_API_KEY`），而裁上下文不必付这个代价。力度默认 `--effort low` ——
> 清理口语没什么可想的。
>
> 模型在中文里会吐半角的 `,` `?`（裁掉上下文后尤其明显），所以结果统一过一遍
> `CJKPunctuation` 做确定性归一，**不往 verbatim 的提示词里加话**。

代码分布：决策与提示词在 `InkfallCore/Text/PostProcessing*`（有单测），
命令行工具那一层在 `InkfallCore/Agents/`（`CLIAgentKind` + 每个工具一个目录）。
**要加 gemini-cli / codex-cli，只需要给 `CLIAgentKind` 加一个 case**：
补上可执行文件名、搜索路径、命令行怎么拼、JSONL 怎么解，调用方一行不用动。

---

## 隐私

- **转写在本机**（WhisperKit + CoreML/ANE），音频不出机器。云端转写还没接。
- **加工会把文字发出去**（如果你开了云端 API 或 Claude Code 那条路）。
  只想要本地的话，把预设设成「基础整理」——那一档一个字节都不出机器。
- **贾维斯待命不留任何文字**：每段转写完只用来扫关键词，扫完就丢。
- **助手会把内容发出去**：问句、选中的文字会经 Claude Code 发给 Anthropic。
  不想要就关掉「按住提问」与语音命令。
- **落笔的每一段录音会留在笔记目录里**（`attachments/<笔记 id>/voice-<ms>.wav`），
  全篇转译要靠它重跑。删掉那篇笔记时整个目录一起删。
- 笔记、设置、截图都在 `~/Library/Application Support/app.inkfall.native/`。
- 集成 API 默认**关**；开着时只监听 `127.0.0.1`。

---

## 构建

需要 macOS 14+、Xcode（Swift 6）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。
语音助手另外需要 [Claude Code](https://claude.com/claude-code) CLI；`tmux` 可选
（没有就回落成脱管进程，只是 attach 不上去看）。

```sh
brew install xcodegen        # tmux 可选
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project InkfallNative.xcodeproj -scheme InkfallNative \
  -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Inkfall.app
```

> 本机 `xcode-select` 若指向 CommandLineTools 就要显式给 `DEVELOPER_DIR`，
> 这样不改动系统全局设置。

### 签名（不可省）

工程写死了一个叫 **`Inkfall Dev Signing`** 的签名身份。**ad-hoc 签名每次构建
CDHash 都变，辅助功能授权会随之失效** —— 每改一行都要重新授权，没法开发。

自己造一个（钥匙串访问 → 证书助理 → 创建证书）：名称 `Inkfall Dev Signing`、
身份类型「自签名根证书」、证书类型「代码签名」。或者改 `project.yml` 里的
`CODE_SIGN_IDENTITY` 换成你自己的。

麦克风 entitlement 必须声明在 **`project.yml` 的 `entitlements.properties`** 里
（XcodeGen 会重写 entitlements 文件，手写进文件的键会被静默清空；而少了它，
签名构建的麦克风会被 macOS 直接拒绝**且不弹任何提示**）。

### 测试

```sh
cd Packages/InkfallCore && \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

**319 个纯逻辑测试，0 失败。** 绝大部分从 `inkfall-app` 的
`regression_tests.rs` 移植 —— 重写期间唯一的安全网。

### 自测：UI 与系统集成怎么取证

屏幕捕获受 TCC 限制、刘海是 click-through 的、热键要真实 HID 事件 ——
这些都不是单测覆盖得了的。所以 App 自带一组自测入口，**在签名真机构建上**
合成真实事件走完整条链路，把取证打进 `/tmp/inkfall-native.log`：

```sh
open -n build/DerivedData/Build/Products/Debug/Inkfall.app --args --jarvis-test
```

| 参数 | 验什么 |
|------|--------|
| `--hotkey-selftest` | 合成右 ⌥ 按住 → tap → 匹配器 → 录音 |
| `--record-test N` | 真录 N 秒，落 WAV，打出提交裁决 |
| `--transcribe-test <wav>` | 本地转写连跑三遍，验结果稳定 |
| `--note-test <wav>` | 落笔：连续录音 → 自动切段 → 按序落正文 → 落盘 |
| `--note-hover-test` | 刘海 hover 条：悬停展开、按钮点得动、click-through 还原 |
| `--note-key-test` | 编辑器 ⌘B / Tab / 回车 / ⌘Z 走真实 CGEvent |
| `--jarvis-test` | 待命 → 命中 → 倒计时 → 撤销 / 真在终端里执行；共跑 |
| `--claude-test` | `claude -p` 两轮，验第二轮**记得**第一轮；联网轮 |
| `--ask-test` | 双击并按住的手势识别、提问态、关掉开关后退化 |
| `--integration-test` | 两道门禁 + 五条路由 + 真起 node 跑 MCP 桥 |
| `--process-test [文本]` | 九个预设的提示词 + 真发一次加工请求；`--engine cloud\|cli`、`--preset <名>`、`--effort <档>` 可覆盖 |
| `--note-process-test` | 落笔的段落**加工之后仍然按说话顺序**落进正文 |
| `--seed-note-test <wav…>` | 用真实音频造一篇落笔笔记，验每段的音频**真的留在了笔记目录里** |
| `--full-transcribe-test [id]` | 全篇转译：拼音频 → 跑一次带分离的转写 → 落成新笔记 |
| `--self-paste-test` | 粘贴目标是**落音自己的窗口**时不崩（2026-08-04 那次崩溃的守卫） |
| `--verify-page <名>` | 把某个设置页**真正渲染出来的文字**读回来，并截一张图 |

还有一组只读的 HTTP 观测面（不需要 token，只绑回环）：

```sh
curl -s 127.0.0.1:48765/health            | python3 -m json.tool
curl -s 127.0.0.1:48765/debug/overlay/state   # 刘海真实几何
curl -s 127.0.0.1:48765/debug/note/state      # 当前会话
curl -s '127.0.0.1:48765/debug/jarvis/match?text=克劳德，你好'   # 干跑，不执行
```

---

## 仓库结构

```
App/                 macOS 宿主：AppKit 窗口/菜单栏 + SwiftUI 视图 + 系统集成
  Pipeline/          会话控制器、贾维斯、Claude Code 助手、集成 API
  Platform/          AUHAL 录音、CGEventTap、AX 自动化、终端启动、HTTP 服务
  Windows/           刘海岛、落笔面板、合并窗
Packages/InkfallCore 纯 Swift、无平台依赖 —— 与 inkfall-mobile 共用的那一半
project.yml          XcodeGen 的唯一真相源（改了要重新 generate）
```

**纯逻辑一律放 `InkfallCore` 并先写测试。** 协调器需要活的 App 环境，测不了；
能测的部分就必须测。这里不许 `import AppKit`。

## InkfallCore 里有什么

- `HotkeyMatcher` — 和弦匹配、事件吞噬、右 ⌥ 单击的污染检测、ask 双击并按住、
  三层按键状态自愈。回归用例全部用**合成事件**驱动：「tap 被禁用期间丢了
  key-up」「Caps Lock 发奇数个 keycode-255」这类序列真机按不出来
- `JarvisMachine` / `SessionMachine` — sink × filter 正交模型、⌥, 的动作表、
  引用计数式的释放语义。含一条穷举全状态的性质测试：**esc/↩ 的抢占绝不能遗留**
  （遗留 = 用户的 Escape 键全系统失效，而屏幕上没有任何解释）
- `VoiceCommandMatcher` — 关键词归一化（忽略大小写与 ASR 爱插的全角空格，
  「克 劳 德」也匹配）、位置约束、`{text}` 的两侧重连
- `ClaudeCode` — `claude -p` 的参数、脚本与回复解析
- `HallucinationFilter` — 字幕组片尾名单、纯标点输出、解码退化的重复刷屏
- `TranscriptionLanguagePolicy` — 三种模式 + 会话内语言锁定（**两段判出同一种
  语言才锁**：Whisper 对短句经常判错，而第一句最短最急）
- `SilenceSegmenter` — 1.3 s 停顿切段，自适应噪声底 + 迟滞
- `RecordingSubmissionPolicy` — 700 ms / 4 KB / 150 ms 有效语音，**解析失败 fail-open**
- `OrderedPasteQueue` — 按提交顺序落地，队头未完成则全部 hold
- `LocalHTTPParser` / `IntegrationRoute` — 集成 API 的语法与路由
- `AppSettings` / `ShortcutsConfig` / `VoiceCommand` — **逐字段**容错解码
- `OverlayGeometry` — 刘海胶囊尺寸：宽跟「扫描 armed」、高跟「正在采集」，
  两个独立的轴

---

## 几个不得不这么做的地方

**录音强制绑内置麦克风。** 高层音频引擎在你一碰输入的瞬间就用*系统默认输入
设备*初始化 I/O unit；默认是蓝牙耳机时，macOS 立刻把它从 A2DP 切到低保真 HFP，
**全系统音质塌掉** —— 哪怕没在录音。所以走 AUHAL 手动绑设备。

**CGEventTap 跑专用高优先级线程。** 回调有硬性超时，主线程一被 SwiftUI 布局
或磁盘 IO 卡住，macOS 就直接把 tap 禁掉，症状是热键毫无征兆地整体失灵。
被禁用后有两条恢复路径：一次性伪事件通知 **+ 3 秒看门狗**（有些禁用不发通知）。

**前台 App 判定必须走 AX，不能用 `NSWorkspace.frontmostApplication`。**
后者靠主线程 run loop 上的通知更新，而插入路径里全是 `Thread.sleep` ——
主线程一堵它就停在旧值上，跨 App 插入会被误判成「目标已在前台」，
⌘V 打进别人窗口。

**绝不给 WhisperKit 设 `promptTokens`。** 用 Whisper 的 prompt 做专有名词提示
是很自然的想法（把「落音」喂进去，免得写成「洛因」），但在 WhisperKit +
CoreML 上实测：带 prompt 时**第一次**转写正常，**第二次开始一律返回空**。
改成解码之后的确定性替换（`VocabularyCorrector`），规则由用户显式给出。

**Whisper 会在没有语音的音频上编字幕组片尾。** 训练数据里塞满了 YouTube 字幕，
所以喂静音、呼吸声或背景音乐时它会自信地吐出「字幕由 Amara.org 社群提供」
「請不吝點贊 訂閱」。这些句子解码置信度很高，阈值拦不住，只能按名单整条丢弃
（`HallucinationFilter`）。**只在整段就是套话时丢**，绝不做子串删除 ——
用户完全可能真的说「谢谢观看」。

**刘海宽度读真值。** `NSScreen.auxiliaryTopLeftArea` 是 Swift-only API，
Tauri 版的 Rust 读不到只能硬编码 184pt；本机实测 **179pt** —— 胶囊因此一直
比真实刘海宽 5pt。原生版直接读真值（读不到才回落 184）。

**tmux 窗口直接跑脚本，不走「常驻 shell + send-keys」。** 后者要等用户的交互式
shell 先到提示符，而那是没有上界的等待（source 一下 gcloud 的 completion 就要
几秒）；提示符出现之前敲进去的键会被 tty 回显、再被 ZLE 初始化丢掉 ——
命令躺在 pane 里，回车没反应。

---

## 已定的两个方向

**本地推理运行时随程序打包。** 要求用户自己建 `~/.venvs/inkfall-mlx` 是不可
接受的门槛 —— 装不上就等于没有离线能力，而离线降级是「云端挂了不打断你」的
唯一保障。原生版用 [WhisperKit](https://github.com/argmaxinc/WhisperKit)
（纯 Swift + CoreML/ANE）**编译进二进制**。没选 MLX Swift 是因为它没有 Whisper
实现；没选 whisper.cpp 是因为它不再提供 `Package.swift`。

模型权重仍然**按需下载**到 App 容器，不进包体：Large v3 Turbo 有 1.5 GB。
「不需要单独安装」指的是运行时，不是权重。启动时预热已下载的模型，
空闲 5 分钟再把内存还给系统。

**编辑器（将来的协同编辑）留在 WebView。** 协同里最难的那部分（远程操作不打乱
本地光标、选区随文本位移、撤销栈区分本地/远程）`y-codemirror.next` 已经做完了。
Swift 只做外壳，CRDT 传输层放 Swift 侧（`URLSessionWebSocketTask`）。

## 数据

笔记、设置、截图、集成 token 都在
`~/Library/Application Support/app.inkfall.native/`。设置**读**得动旧版
`app.inkfall.desktop/settings.json`（验证容错解码原地兼容），但**写**进自己的
目录 —— 重写期间绝不碰在用的数据。

## 参与

- 改行为之前先读 [`spec/10-debt-and-invariants.md`](../inkfall-docs/spec/10-debt-and-invariants.md)：
  20 条线上事故换来的不变量，重写最容易一条不落地重新踩一遍。
- 时间常数、提示词、keycode 一律以 spec 为准，不要凭记忆写。
- 纯逻辑改动：`swift test` 必须全绿。
- UI / 系统集成改动：**必须签名构建 + 真机验证**，并在交付时说明验了什么、
  哪些没验。TCC 权限、刘海几何、粘贴时序都不是单测能覆盖的。
- 计划中的工作在 [Issues](https://github.com/DDnim/inkfall-native/issues)。

## 许可证

[GNU AGPL-3.0](LICENSE)。

Copyright (C) 2026 Inkfall contributors.

这是自由软件：你可以在 GNU Affero 通用公共许可证第 3 版（或任何更新版本）
的条款下重新发布和修改它。分发本程序的修改版本 —— **包括通过网络提供服务** ——
必须同样以 AGPL 开放对应的源代码。

本程序不提供任何担保，详见许可证全文。
