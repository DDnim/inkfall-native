# inkfall-native

落音 Inkfall 桌面端的 **原生 Swift / SwiftUI 重写**。目标是取代
`inkfall-app`（Tauri 2 / Rust + WebView）。

完整技术规格在 [`../inkfall-docs/spec/`](../inkfall-docs/spec/)（13 份）。
设计集在 claude.ai/design 的「Inkfall Native · Swift 重写」项目。

---

## 当前状态

**里程碑 0：地基 + 权限引导。** 能构建、能启动、能授权。录音与转写还没接上。

| 模块 | 状态 |
|------|------|
| `InkfallCore` 纯逻辑 + 73 个测试 | ✅ 全绿 |
| 菜单栏常驻（无 Dock 图标） | ✅ |
| 首启权限引导（三步，必需项卡住下一步） | ✅ |
| 设置读写（容错解码，兼容现有 `settings.json`） | ✅ 读兼容 / 写自己的目录 |
| **合并窗**（笔记主页 + 设置子页） | ✅ 980×760 |
| **刘海岛**（画布 520×168，layer 25，click-through） | ✅ 壳 + 几何 |
| **落笔面板**（非激活 NSPanel，layer 3） | ✅ 壳 |
| 录音（AUHAL）· 热键（CGEventTap）· 粘贴（AX） | ⬜ 里程碑 1 |
| **贾维斯** · **编辑窗口** | ⬜ 本轮刻意不做 |

### 刘海宽度：原生版拿到了真值

`NSScreen.auxiliaryTopLeftArea` 是 Swift-only API，Tauri 版的 Rust 读不到，
只能硬编码 184pt。本机实测 **179pt** —— 胶囊因此一直比真实刘海宽 5pt，
融合柱也跟着错。原生版直接读真值（读不到才回落 184）。

## InkfallCore 已落地的东西

全部是从 `inkfall-app` 的 `regression_tests.rs` 移植过来的纯逻辑 —— 重写期间
唯一的安全网。**73 个测试，0 失败。**

- `SessionMachine` — sink × filter 正交模型、动作表、引用计数式的释放语义
- `SilenceSegmenter` — 1.3 s 停顿切段，自适应噪声底 + 迟滞（与 mobile 同参）
- `RecordingSubmissionPolicy` — 700 ms / 4 KB / 150 ms 有效语音，**解析失败 fail-open**
- `SilenceTrimmer` — 首尾各留 300 ms，内部停顿压到 2 s
- `OrderedPasteQueue` — 按提交顺序粘贴，队头未完成则全部 hold，`advancePast` 防 id 撞车
- `BasicPolisher` — 中英填充词、笑声折叠、标点合并、句末补标点
- `AppSettings` / `ShortcutsConfig` / `NoteSession` / `HistoryEntry` — **逐字段**容错解码
- `CloudFailureKind` — 只有网络/5xx 降级，鉴权与配额必须浮出来
- `OverlayGeometry` — 刘海胶囊尺寸。宽跟「扫描 armed」、高跟「正在采集」两个
  独立的轴，加上 8 条性质测试（装得进画布 / arming 不缩小 / 待命绝不下坠 /
  转写与录音等高 / 结果卡矮一档 / 暂停与录音同尺寸 …）

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

## 已定的两个方向

**编辑器留在 WebView。** 协同编辑里最难的那部分（远程操作不打乱本地光标、
选区随文本位移、撤销栈区分本地/远程、他人光标渲染）`y-codemirror.next` 已经做完了。
Swift 只做外壳：窗口、菜单、文件 IO、系统集成。CRDT 传输层放 Swift 侧
（`URLSessionWebSocketTask`），JS 只产出/消费二进制 update —— 这样能复用系统的
证书校验、代理设置与断线重连，也不用在 WebView 里折腾 CORS。

**MLX 随程序打包。** 现在要求用户自己建 `~/.venvs/inkfall-mlx` 是不可接受的。
重写后本地推理走原生 Swift 栈，运行时随 App 分发，用户不需要装任何东西。
**模型权重仍然按需下载**到 App 容器 —— 1.7 GB 的 MOSS 塞进 .app 不现实，
「不需要单独安装」指的是运行时，不是权重。详见 `../inkfall-docs/spec/05`。

## 数据兼容

这一版**读**现有 `~/Library/Application Support/app.inkfall.desktop/settings.json`
（验证容错解码确实原地兼容），但**写**进 `app.inkfall.native/` ——
骨架阶段绝不碰在用的数据。两边正式合流要等录音与笔记接上之后。
