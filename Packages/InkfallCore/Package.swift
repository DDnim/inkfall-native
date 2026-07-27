// swift-tools-version: 6.0
import PackageDescription

/// InkfallCore — 纯 Swift，无平台依赖。
///
/// 这里放的是**桌面端与 iOS 端可以共用**的那一半：断句、提交策略、静音压缩、
/// 有序粘贴队列、基础润色、会话状态机、容错解码的数据模型、降级判定、提示词。
/// 系统集成（CGEventTap / AUHAL / AX / NSPanel / 子进程）全部留在 App 侧。
///
/// 见 inkfall-docs/spec/09-mobile-web-reuse.md 与 spec/11-swift-target-architecture.md。
let package = Package(
    name: "InkfallCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "InkfallCore", targets: ["InkfallCore"])
    ],
    targets: [
        .target(name: "InkfallCore"),
        .testTarget(name: "InkfallCoreTests", dependencies: ["InkfallCore"]),
    ]
)
