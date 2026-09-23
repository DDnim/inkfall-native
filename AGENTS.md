# Inkfall Native AI Instructions

原生 Swift / SwiftUI 重写的 macOS 客户端。**减法版**（2026-09-23 起）：只保留
「按住说话」与「切换录音」两个快捷键功能，其余（落笔、贾维斯、问助手、截图、
笔记、本地集成 API、Claude Code 引擎）已删除。范围见 GitHub milestone「减法版」。

## 仓库结构

- `Packages/InkfallCore/` — 纯 Swift、无平台依赖。热键匹配、提交策略、静音压缩、
  本地润色、容错解码的数据模型、降级判定、加工的提示词与裁决、云端请求体。
  **与 inkfall-mobile 共用的那一半**，不许在这里 import AppKit。
- `App/` — macOS 宿主：AppKit 菜单栏 + SwiftUI 设置窗 + 系统集成。
  `App/main.swift` 是协调器：两个手势、转写 → 加工 → 粘贴、自测入口。
- `project.yml` — XcodeGen 的唯一真相源。改了它必须重新 `xcodegen generate`。

## 操作规则

- 纯逻辑一律放 InkfallCore 并**先写测试**。协调器需要活的 App 环境，测不了；
  能测的部分就必须测。
- 时间常数、提示词、keycode 一律以既有代码与单测为准，不要凭记忆写。
- **不要把砍掉的功能加回来。** 落笔 / 贾维斯 / 问助手 / 截图 / 笔记 / 集成 API
  的代码在 git 历史里（commit 1f2f8c1 之前），需要时从那里看，不要重写。

## 构建

本机 `xcode-select` 指向 CommandLineTools，所以要显式指定 Xcode：

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project InkfallNative.xcodeproj -scheme InkfallNative \
  -configuration Debug -derivedDataPath build/DerivedData build

open build/DerivedData/Build/Products/Debug/Inkfall.app
```

纯逻辑测试（不需要 Xcode 工程）：

```sh
cd Packages/InkfallCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## 签名（不可省）

- 固定身份 **`Inkfall Dev Signing`**。ad-hoc 签名每次构建 CDHash 都变，
  辅助功能授权会随之失效 —— 每改一行都要重新授权，没法开发。
- 麦克风 entitlement `com.apple.security.device.audio-input` 必须在
  **`project.yml` 的 `entitlements.properties`** 里声明。XcodeGen 会重写
  entitlements 文件，手写进文件的键会被静默清空，而少了它，签名构建的麦克风
  会被 macOS 直接拒绝**且不弹任何提示**。
- 改完签名相关设置后，用 `codesign -d --entitlements -` 验证产物，别只看构建成功。

## 加工（转写之后那一步）

- 决策一律走 `PostProcessingPolicy.decide` + `PostProcessingCoordinator`，
  **两个手势共用同一个实例**。分开写过一次，结果是降级提示、缺 key 的处理、
  日志格式三处各写一遍，然后慢慢长歪 —— 而这一层的分支只在真机上看得见。
- 预设的提示词是 **verbatim 区块**：逐字复制，不要凭记忆重写。
- **加工失败绝不能丢文字**：一律回落本地 basic 润色。鉴权/额度问题要浮出来，
  网络/5xx 才算「降级」。
- 模型在中文里会吐半角标点，结果统一过 `CJKPunctuation.normalize` ——
  **不往 verbatim 的提示词里加话**（同 `VocabularyCorrector` 的道理）。
- 验证用 `--process-test`（可加 `--preset <名>`），不需要麦克风。

## 转写（云端与本地）

- 入口只有一个：`Transcriber`（App 侧）。两个手势都从它过，按
  `transcriptionMode` 走 OpenAI / Groq / Gemini / 本地。**别在调用方
  自己判模式** —— 降级提示、缺 key 的处理、日志格式又会长成三份。
- 请求体与解析在 InkfallCore 的 `TranscriptionAPI` + `MultipartForm`（有单测，
  multipart 是**字节级**钉住的）；App 侧 `CloudTranscriber` 只管发出去与分类失败。
- 降级：只有网络 / 5xx 才回落本地模型，而且要求选中的本地模型**已下载**；
  鉴权 / 配额 / 没配 key 都要浮出来（本地模型在的话先顶上并提醒）。
- 验证用 `--cloud-transcribe-test <wav> [--mode …]`，不需要麦克风。

## 自动粘贴

- **绝不在后台线程上对自家进程调 AX。** AX 对跨进程目标是消息传递（后台线程
  安全），目标在本进程时请求会**就地派发** —— `kAXRaiseAction` 于是变成在
  后台队列上跑 `makeKeyAndOrderFront:`，AppKit 当场 trap，整个 App 挂掉
  （2026-08-04 实测：落笔面板开着 + 逐段自动粘贴）。
  所有 AX 助手都从 `MacAutomation.onMainIfSelf` 过一道，新加的调用别绕开它。
- 回归守卫是 `--self-paste-test`：**必须**用真实的自家窗口 + 后台队列 +
  真实的 `MacAutomation.insert`，而且目标要先掉出前台（否则走 `pasteInPlace`，
  根本碰不到出事的那条路）。

## 两个手势的共享录音器

- ⌥Space 里的那个 ⌥ **就是推杆键本身**：按下它 matcher 先发 `.overlayHoldPressed`，
  `beginHold()` 已经起录；Space 到了才发 `.toggleRecordingPressed`。所以切换录音
  的入口先 `abortSpuriousHold()` 丢掉那截，再接管录音器；松开 ⌥ 的
  `.overlayHoldReleased` 只在 `holdOwnsRecorder` 为真时才停录。
  `HotkeyMatcherTests.testToggleChordIsPrecededByHoldPress` 钉住这个顺序。

## 验证

- 纯逻辑改动：`swift test` 必须全绿。
- UI / 系统集成改动：**必须签名构建 + 装到本机真机验证**。
  TCC 权限、刘海几何、粘贴时序都不是单测能覆盖的。**不要用 open 起自测
  实例去按真实热键** —— 用户日常在跑的那个 App 也会收到合成的按键。
- 交付时说明：测试是否全绿、是否真的构建并启动过。
