# QLaunchpad — Agent 规则

SwiftPM `executableTarget`，由 `scripts/build-app.ts` 打成 `QLaunch.app`，再经 Sparkle 更新。用户机器上没有本机 `build/SwiftPM/…`。

## 资源与本地化（发布后启动崩溃）

- `Sources/QLaunchpad` **禁止**使用 `Bundle.module` / `NSBundle.module`。
- SwiftPM 生成的 accessor 找不到包就 `fatalError`。它只查 `.app` 根目录和编译机硬编码路径；打包后资源在 `Contents/Resources/QLaunchpad_QLaunchpad.bundle`。本机 Debug 能启动是因为那条构建路径还在，Sparkle 升级后立刻崩。
- 读图片、strings 等：用 `QLaunchpadResources.bundle`。
- 读文案：用 `L10n.tr`（已走 `QLaunchpadResources`）。不要再写一套 bundle 查找。
- `Tests/` 可以用 `Bundle.module`。
- `swift run` / 本机 Debug **不能**当作发布包能启动的证据。改资源或本地化后必须跑 `bun test`。
