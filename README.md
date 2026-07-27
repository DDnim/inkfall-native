# inkfall-native

落音 Inkfall 桌面端的 **原生 Swift / SwiftUI 重写**。目标是取代
`inkfall-app`（Tauri 2 / Rust + WebView）。

完整技术规格在 [`../inkfall-docs/spec/`](../inkfall-docs/spec/)（13 份）。
设计集在 claude.ai/design 的「Inkfall Native · Swift 重写」项目。

---

## 当前状态

**里程碑 1 进行中。** 核心闭环已经通：按住右 ⌥ 说话 → 松开 → 本地模型转写
→ 文字粘回你说话前的那个窗口。云端转写、加工预设、切段队列还没接。

| 模块 | 状态 |
|------|------|
| `InkfallCore` 纯逻辑 + 135 个测试 | ✅ 全绿 |
| 菜单栏常驻（无 Dock 图标）· 首启权限引导 | ✅ |
| 设置读写（容错解码，兼容现有 `settings.json`） | ✅ 读兼容 / 写自己的目录 |
| **合并窗** 980×760 · **刘海岛** · **落笔面板** | ✅ 壳 + 几何 |
| 录音（AUHAL，强制绑内置麦克风） | ✅ |
| 热键（CGEventTap，专用线程 + 看门狗 + 三层自愈） | ✅ |
| 本地转写（WhisperKit，随 App 编译进二进制） | ✅ |
| 语言策略（固定/自动 + 会话内锁定）· 静音裁剪 · 长音频 VAD 分块 | ✅ |
| 幻觉过滤 · 专有名词纠错 | ✅ |
| 区分人物（Pyannote，11 MB，与转写并行跑） | ✅ 开关 + 模型管理 |
| 模型管理（切换 / 下载 / 删除 / 磁盘占用 / 空闲卸载） | ✅ 托盘子菜单 + 设置页 |
| 三层插入（零激活 / AX 零焦点 / 切换回落） | ✅ |
| 落笔：连续录音 + 自动切段 + 按序落正文 + 落盘 | ✅ |
| 笔记面板：录音时 markdown 预览 / 停下后 markdown 编辑器 | ✅ |
| 云端转写与降级 · 九个加工预设 | ⬜ |
| 落笔的合并 / 暂停 / 融合进刘海 · **贾维斯** | ⬜ |

实测（M4 MacBook Air，Whisper Large v3 Turbo）：11 秒中文音频，模型常驻内存时
转写 **0.70 s**；冷启动含 CoreML 编译 7.4 s，所以启动时会预热已下载的模型，
空闲 5 分钟再把这 1.5 GB 还给系统。

### 本地转写踩到的两个坑

**绝不给 WhisperKit 设 `promptTokens`。** 用 Whisper 的 prompt 做专有名词提示
是很自然的想法（把「落音」喂进去，免得它写成「洛因」），但在 WhisperKit +
CoreML 上实测：带 prompt 时**第一次**转写正常，**第二次开始一律返回空**。
对一个常驻的听写工具，那等于用一次就废。而且它对这类错误根本没纠过来。
所以改成解码之后的确定性替换（`VocabularyCorrector`），规则由用户显式给出，
只做全词替换、不做模糊匹配 —— 猜「哪个词听起来像专有名词」必然误伤。

**Whisper 会在没有语音的音频上编字幕组片尾。** 训练数据里塞满了 YouTube 字幕，
所以喂给它静音、呼吸声或背景音乐时，它会自信地吐出「字幕由 Amara.org 社群提供」
「請不吝點贊 訂閱」「Thanks for watching!」。这些句子解码置信度很高，
`logProbThreshold` / `noSpeechThreshold` 拦不住，只能按名单整条丢弃
（`HallucinationFilter`）。**只在整段就是套话时丢**，绝不做子串删除 ——
用户完全可能真的说「谢谢观看」。

### 刘海宽度：原生版拿到了真值

`NSScreen.auxiliaryTopLeftArea` 是 Swift-only API，Tauri 版的 Rust 读不到，
只能硬编码 184pt。本机实测 **179pt** —— 胶囊因此一直比真实刘海宽 5pt，
融合柱也跟着错。原生版直接读真值（读不到才回落 184）。

## InkfallCore 已落地的东西

绝大部分是从 `inkfall-app` 的 `regression_tests.rs` 移植过来的纯逻辑 ——
重写期间唯一的安全网。**135 个测试，0 失败。**

- `HotkeyMatcher` — 和弦匹配、事件吞噬、右 ⌥ 单击的污染检测、ask 双击并按住、
  三层按键状态自愈。31 个回归用例全部用**合成事件**驱动：
  「tap 被禁用期间丢了 key-up」「Caps Lock 发奇数个 keycode-255」这类序列
  真机按不出来，只能合成
- `HallucinationFilter` — 字幕组片尾名单、纯标点输出、解码退化的重复刷屏
- `TranscriptionLanguagePolicy` — 固定/自动/偏好三种模式，以及会话内语言锁定
  （Whisper 对短句的自动检测经常判错，一句两个字的中文被当成英文就全是音译垃圾）
- `VocabularyCorrector` — 专有名词全词替换，长规则优先，英文大小写不敏感
- `SpeakerTranscript` — 说话人标签的合并与格式化。**只有一个人时不加标签**
  （独白前面挂一排「说话人 1：」只是噪音），编号从 1 开始，中日韩之间不插空格
- `SessionMachine` — sink × filter 正交模型、动作表、引用计数式的释放语义
- `SilenceSegmenter` — 1.3 s 停顿切段，自适应噪声底 + 迟滞（与 mobile 同参）
- `RecordingSubmissionPolicy` — 700 ms / 4 KB / 150 ms 有效语音，**解析失败 fail-open**
- `SilenceTrimmer` — 首尾各留 300 ms，内部停顿压到 2 s
- `OrderedPasteQueue` — 按提交顺序粘贴，队头未完成则全部 hold，`advancePast` 防 id 撞车
- `BasicPolisher` — 中英填充词、笑声折叠、标点合并、句末补标点
- `AppSettings` / `ShortcutsConfig` / `NoteSession` / `HistoryEntry` — **逐字段**容错解码
- `CloudFailureKind` — 只有网络/5xx 降级，鉴权与配额必须浮出来
- `OverlayGeometry` — 刘海胶囊尺寸。宽跟「扫描 armed」、高跟「正在采集」两个
  独立的轴，加上 8 条性质测试

## 系统集成里几个不得不这么做的地方

**录音强制绑内置麦克风。** 高层音频引擎在你一碰输入的瞬间就用*系统默认输入设备*
初始化 I/O unit；默认是蓝牙耳机时，macOS 立刻把它从 A2DP 切到低保真 HFP，
**全系统音质塌掉** —— 哪怕没在录音。所以走 AUHAL 手动绑设备。

**CGEventTap 跑专用高优先级线程。** 回调有硬性超时，主线程一被 SwiftUI 布局
或磁盘 IO 卡住，macOS 就直接把 tap 禁掉，症状是热键毫无征兆地整体失灵。
被禁用后有两条恢复路径：一次性伪事件通知 **+ 3 秒看门狗**（有些禁用不发通知）。

**前台 App 判定必须走 AX，不能用 `NSWorkspace.frontmostApplication`。**
后者靠主线程 run loop 上的通知更新，而插入路径里全是 `Thread.sleep`——
主线程一堵它就停在旧值上，跨 App 插入会被误判成「目标已在前台」，
⌘V 打进别人窗口。

## 构建与运行

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project InkfallNative.xcodeproj -scheme InkfallNative \
  -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Inkfall.app
```

测试：

```sh
cd Packages/InkfallCore && \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

> 本机 `xcode-select` 指向 CommandLineTools，所以要显式给 `DEVELOPER_DIR`。
> 这样不改动系统全局设置。

## 落笔（笔记模式）

⌥Space 开始一段连续录音：说到停顿约 1.3 秒自动切一段，每段独立转写，
按**说话顺序**落进正文（第 3 段先转完也得等第 2 段 —— `OrderedPasteQueue`）。
再按 ⌥Space 停止，停下来时还在飞的段照常转写补进正文，绝不丢数据。

- **录音中**是只读的 markdown 预览（[swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui)，
  底层 swift-cmark）。此刻不该可编辑 —— 下一段随时追加进来会把光标挤走。
- **停下来**变成 markdown 编辑器（[HighlightedTextEditor](https://github.com/kyle-n/HighlightedTextEditor)，
  NSTextView + 正则高亮）。
- 每次开始录音都**新建一篇**笔记，本轮不做合并。笔记落在 `history.json`
  （名字沿用 Tauri 版，产品上它已经是「笔记」），最多 100 条。

## 已定的两个方向

**编辑器留在 WebView。** 协同编辑里最难的那部分（远程操作不打乱本地光标、
选区随文本位移、撤销栈区分本地/远程、他人光标渲染）`y-codemirror.next` 已经做完了。
Swift 只做外壳：窗口、菜单、文件 IO、系统集成。CRDT 传输层放 Swift 侧
（`URLSessionWebSocketTask`），JS 只产出/消费二进制 update —— 这样能复用系统的
证书校验、代理设置与断线重连，也不用在 WebView 里折腾 CORS。

**本地推理运行时随程序打包。** 现在要求用户自己建 `~/.venvs/inkfall-mlx`
是不可接受的门槛 —— 装不上就等于没有离线能力，而离线降级是「云端挂了不打断你」
的唯一保障。原生版用 [WhisperKit](https://github.com/argmaxinc/WhisperKit)
（纯 Swift + CoreML/ANE），**编译进二进制**，用户不需要装任何东西。

没选 MLX Swift 是因为它没有 Whisper 实现；没选 whisper.cpp 是因为它已经不再
提供 `Package.swift` —— 两条路都要自己搓构建系统，反而离「装完就能用」更远。

**模型权重仍然按需下载**到 App 容器，不进包体：Large v3 Turbo 有 1.5 GB，
塞进 .app 会拖垮更新包。「不需要单独安装」指的是运行时，不是权重。

## 数据兼容

这一版**读**现有 `~/Library/Application Support/app.inkfall.desktop/settings.json`
（验证容错解码确实原地兼容），但**写**进 `app.inkfall.native/` ——
骨架阶段绝不碰在用的数据。两边正式合流要等录音与笔记接上之后。

## 许可证

[GNU AGPL-3.0](LICENSE)。

Copyright (C) 2026 Inkfall contributors.

这是自由软件：你可以在 GNU Affero 通用公共许可证第 3 版（或任何更新版本）
的条款下重新发布和修改它。分发本程序的修改版本 —— **包括通过网络提供服务** ——
必须同样以 AGPL 开放对应的源代码。

本程序不提供任何担保，详见许可证全文。
