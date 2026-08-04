# Inkfall Native AI Instructions

原生 Swift / SwiftUI 重写的 macOS 客户端。规格集在 `../inkfall-docs/spec/`。

## 仓库结构

- `Packages/InkfallCore/` — 纯 Swift、无平台依赖。断句、提交策略、静音压缩、
  有序粘贴队列、本地润色、会话状态机、容错解码的数据模型、降级判定、
  加工的提示词与裁决。**与 inkfall-mobile 共用的那一半**，
  不许在这里 import AppKit。
- `Packages/InkfallCore/Sources/InkfallCore/Agents/` — 命令行编码助手那一层。
  `CLIAgent.swift` 定的是共同形状（可执行文件名、搜索路径、命令行怎么拼、
  JSONL 怎么解），每个工具一个子目录（现在只有 `ClaudeCode/`）。
  **加 gemini-cli / codex-cli 就是加一个 `CLIAgentKind` 的 case + 一个目录**，
  调用方（`PostProcessingCoordinator` / `CLIAgentRunner`）一行不用动。
- `App/` — macOS 宿主：AppKit 窗口/菜单栏 + SwiftUI 视图 + 系统集成。
  `App/Agents/` 是上面那一层的宿主侧（找可执行文件、起子进程、流式读）。
- `project.yml` — XcodeGen 的唯一真相源。改了它必须重新 `xcodegen generate`。

## 操作规则

- **改任何行为之前先读 `../inkfall-docs/spec/10-debt-and-invariants.md`**。
  那 20 条是线上事故换来的不变量，重写最容易一条不落地重新踩一遍。
- 纯逻辑一律放 InkfallCore 并**先写测试**。协调器需要活的 App 环境，测不了；
  能测的部分就必须测。
- 时间常数、提示词、keycode 一律以 spec 为准，不要凭记忆写。

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
  **听写与落笔共用同一个实例**。分开写过一次，结果是降级提示、缺 key 的处理、
  日志格式三处各写一遍，然后慢慢长歪 —— 而这一层的分支只在真机上看得见。
- spec/05 §6 的提示词是 **verbatim 区块**：逐字复制，不要凭记忆重写。
- **加工失败绝不能丢文字**：一律回落本地 basic 润色。鉴权/额度问题要浮出来
  （A15），网络/5xx 才算「降级」。
- CLI 那条路**必须把上下文裁干净**（`--tools "" --disable-slash-commands
  --strict-mcp-config --setting-sources ""`）。裸调实测 **19 982 token /
  $0.2006**，裁完 **256 token / $0.0027**。**不要用 `--bare`** —— 它连 OAuth
  一起跳过，反而要 API key。力度默认 `--effort low`。
- 模型在中文里会吐半角标点，结果统一过 `CJKPunctuation.normalize` ——
  **不往 verbatim 的提示词里加话**（同 `VocabularyCorrector` 的道理）。
- 验证用 `--process-test`（可加 `--engine cloud|cli` / `--preset <名>` /
  `--effort <档>`）和 `--note-process-test`，都不需要麦克风。

## 验证

- 纯逻辑改动：`swift test` 必须全绿。
- UI / 系统集成改动：**必须签名构建 + 装到本机真机验证**。
  TCC 权限、刘海几何、粘贴时序都不是单测能覆盖的。
- 交付时说明：测试是否全绿、是否真的构建并启动过。
