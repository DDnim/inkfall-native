# inkfall-native

落音 Inkfall 的 macOS 客户端 —— **原生 Swift / SwiftUI**。按住一个键说话，
文字落回你刚才那个窗口。转写可以在本机跑（推理运行时编译进二进制，不需要
另外装 Python 环境），也可以走云端：落音云、或者自带 key 的
OpenAI / Groq / Gemini。转写完可以再过一遍模型**加工**（云端 API）。

这个仓库是 `inkfall-app`（Tauri 2 / Rust + WebView）的重写，目标是取代它。

> **状态：减法版重构中（2026-09-23 起）。** 桌面端只保留两个快捷键功能，
> 其余（落笔笔记、贾维斯、问助手、截图、本地集成 API）已整体砍掉。
> 自动更新、本地化还没接，现在要用只能自己构建，见 [构建](#构建)。
> 范围见 milestone [减法版](https://github.com/DDnim/inkfall-native/milestone/7)。

---

## 它能做什么

| 手势 | 做什么 |
|------|--------|
| **按住右 ⌥** | 按住说话。松开 → 转写 → 文字插回你说话前的那个窗口 |
| **⌥Space** | 切换录音。按一下开始长录音，再按一下 → 转写 → 插回 |

两个快捷键都可以改（`shortcuts.json` 的 `overlayHold` / `toggleRecording`）。
除此之外没有别的手势。

### 加工：转写完再过一遍模型

九个预设（基础整理 / 轻度整理 / 清理口语 / 润色表达 / 简短总结 / 邮件 /
笔记 / 会议纪要 / 自定义），走 OpenAI / Groq / Gemini 的 API（key 存钥匙串；
Groq 的 `gpt-oss-20b` 又快又便宜，是默认）。

**「基础整理」是纯本地规则**（去口头禅、补标点），不联网也不要 key。
录音短于 3 秒、不足 10 字、带说话人标签、或者根本没配 key 时，都会自动退回
它 —— **文字永远不会因为加工失败而丢**。鉴权与额度问题不降级，会明说
（静默重试只会掩盖一个用户必须处理的问题）。

模型在中文里会吐半角的 `,` `?`，所以结果统一过一遍 `CJKPunctuation`
做确定性归一，**不往 verbatim 的提示词里加话**。

代码分布：决策与提示词在 `InkfallCore/Text/PostProcessing*`（有单测）。

---

## 隐私

- **转写默认在本机**（WhisperKit + CoreML/ANE），音频不出机器。选了落音云或自带 key
  的云端转写时，音频会发给那一家；云端不可达（网络 / 5xx）时降级回本地模型，
  鉴权与配额问题不会被静默重试。
- **加工会把文字发出去**（如果你开了云端 API）。只想要本地的话，
  把预设设成「基础整理」——那一档一个字节都不出机器。
- 设置与模型权重都在 `~/Library/Application Support/app.inkfall.native/`。
  录音只在内存里过一遍，转写完即丢，不落盘。

---

## 构建

需要 macOS 14+、Xcode（Swift 6）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
brew install xcodegen
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

**190 个纯逻辑测试，0 失败。** 绝大部分从 `inkfall-app` 的
`regression_tests.rs` 移植 —— 重写期间唯一的安全网。

### 自测：UI 与系统集成怎么取证

屏幕捕获受 TCC 限制、刘海是 click-through 的、热键要真实 HID 事件 ——
这些都不是单测覆盖得了的。所以 App 自带一组自测入口，**在签名真机构建上**
合成真实事件走完整条链路，把取证打进 `/tmp/inkfall-native.log`：

```sh
open -n build/DerivedData/Build/Products/Debug/Inkfall.app --args --hotkey-selftest
```

| 参数 | 验什么 |
|------|--------|
| `--hotkey-selftest` | 合成右 ⌥ 按住 → tap → 匹配器 → 录音 |
| `--record-test N` | 真录 N 秒，落 WAV，打出提交裁决 |
| `--transcribe-test <wav>` | 本地转写连跑三遍，验结果稳定 |
| `--cloud-transcribe-test <wav> [--mode …]` | 云端转写：key、地址、multipart、解析、降级 |
| `--loop-test <wav> <file>` | 右⌥ 按住 → 外放 → 松开 → 转写 → 粘回文本编辑 |
| `--paste-test` / `--autopaste-test` | 三层插入 / 剪贴板卫生与降级 |
| `--process-test [文本]` | 九个预设的提示词 + 真发一次加工请求；`--preset <名>` 可覆盖 |
| `--self-paste-test` | 粘贴目标是**落音自己的窗口**时不崩（2026-08-04 那次崩溃的守卫） |
| `--model-download-test <id>` | 本地模型下载流程 |
| `--menu-dump` | 托盘菜单的实际结构 |

---

## 仓库结构

```
App/                 macOS 宿主：AppKit 菜单栏 + SwiftUI 设置窗 + 系统集成
  Pipeline/          转写（本地 / 云端）、加工、模型目录
  Platform/          AUHAL 录音、CGEventTap、AX 自动化
  Windows/           刘海岛、设置窗
Packages/InkfallCore 纯 Swift、无平台依赖 —— 与 inkfall-mobile 共用的那一半
project.yml          XcodeGen 的唯一真相源（改了要重新 generate）
```

**纯逻辑一律放 `InkfallCore` 并先写测试。** 协调器需要活的 App 环境，测不了；
能测的部分就必须测。这里不许 `import AppKit`。

## InkfallCore 里有什么

- `HotkeyMatcher` — 和弦匹配、事件吞噬、三层按键状态自愈。回归用例全部用
  **合成事件**驱动：「tap 被禁用期间丢了 key-up」「Caps Lock 发奇数个
  keycode-255」这类序列真机按不出来
- `HallucinationFilter` — 字幕组片尾名单、纯标点输出、解码退化的重复刷屏
- `TranscriptionLanguagePolicy` — 三种模式 + 会话内语言锁定（**两段判出同一种
  语言才锁**：Whisper 对短句经常判错，而第一句最短最急）
- `RecordingSubmissionPolicy` — 700 ms / 4 KB / 150 ms 有效语音，**解析失败 fail-open**
- `TranscriptionAPI` / `MultipartForm` / `TextGenerationAPI` — 云端请求体与解析，
  multipart 是字节级钉住的
- `AppSettings` / `ShortcutsConfig` — **逐字段**容错解码
- `OverlayGeometry` — 刘海胶囊尺寸

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

---

## 已定的方向

**本地推理运行时随程序打包。** 要求用户自己建 `~/.venvs/inkfall-mlx` 是不可
接受的门槛 —— 装不上就等于没有离线能力，而离线降级是「云端挂了不打断你」的
唯一保障。原生版用 [WhisperKit](https://github.com/argmaxinc/WhisperKit)
（纯 Swift + CoreML/ANE）**编译进二进制**。没选 MLX Swift 是因为它没有 Whisper
实现；没选 whisper.cpp 是因为它不再提供 `Package.swift`。

模型权重仍然**按需下载**到 App 容器，不进包体：Large v3 Turbo 有 1.5 GB。
「不需要单独安装」指的是运行时，不是权重。启动时预热已下载的模型，
空闲 5 分钟再把内存还给系统。

## 数据

设置与模型权重都在 `~/Library/Application Support/app.inkfall.native/`。设置**读**得动旧版
`app.inkfall.desktop/settings.json`（验证容错解码原地兼容），但**写**进自己的
目录 —— 重写期间绝不碰在用的数据。

## 参与

- 时间常数、提示词、keycode 一律以既有代码与单测为准，不要凭记忆写。
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
