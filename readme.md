# QLaunch

简单、高性能的 macOS Launchpad 替代方案。面向发布级体验：128pt 图标、高帧率翻页、高斯模糊壁纸、液态玻璃搜索框、渐入渐出窗口。

## 特性

| 能力 | 实现 |
|------|------|
| **128pt 图标** | 网格固定 128pt 显示，Metal atlas 使用 256px tile（2× 视网膜） |
| **高帧率动画** | `CADisplayLink` 驱动，最高 120fps；分页弹簧 + 展示缩放淡入 |
| **高斯模糊背景** | 读取当前桌面壁纸，`CIGaussianBlur` 真模糊 + 暗色叠层与 vignette |
| **滚动翻页** | 精确触控板相位 / 惯性、边缘橡胶回弹、松手按速度吸附整页 |
| **液态玻璃搜索** | macOS 26+ `glassEffect`；旧系统分层 material + 高光描边近似 |
| **窗口渐入渐出** | 面板 alpha 与内容 scale（0.88→1）同步的 open / close 动画 |

其它能力：

- AppKit `NSPanel`：`popUpMenu` 层级、跨 Space、全屏辅助
- 菜单栏入口：显示 / 隐藏、Settings、退出
- App 扫描：`/Applications`、`/System/Applications`、Utilities、用户 Applications，按 Bundle ID 去重
- Icon 缓存：`~/Library/Caches/com.qlaunchpad.icons`
- 交互：点击启动、拖拽排序、←/→ 翻页、页码指示器
- 搜索：名称 / Bundle Identifier，90ms 节流
- 快捷键：`⌘ Space` 开关，`Esc` 关闭，`⌘ ,` 设置

## 应用图标（Icon Composer）

优先使用 Icon Composer 多层源：

```text
icons/QLaunch.icon          # 首选
icons/AppIcon.icon          # 备选
icons/QLaunchpad.icon       # 备选
```

打包时 `scripts/build-app.ts` 会用 `actool` 编译为：

- `Contents/Resources/Assets.car` — macOS 26+ 液态玻璃 / 系统投影
- `Contents/Resources/QLaunch.icns` — 旧系统与 Finder 回退
- 并刷新 `Sources/QLaunchpad/Resources/QLaunchpadAppIcon.png` 供关于页与 `swift run`

可用环境变量覆盖源路径：`QLAUNCHPAD_ICON=/path/to/Your.icon`。

图标编译结果缓存在 `build/icon-cache/`，**源 `.icon` 未改时 `bun run dev` 会跳过 actool**。强制重编：

```sh
QLAUNCHPAD_FORCE_ICON=1 bun run dev
```

若当前 `actool` 无法处理部分高级字段（refractivity 等），脚本会自动做兼容规范化（保留阴影与半透明），并在日志中提示。没有 `.icon` 时回退为 PNG → icns。

菜单栏图标仍为独立资源：`qlaunch-menubar.png`（template）。

## 官网

产品官网在 `web/`，架构与 QCopy/web 一致（Vite + React + TypeScript，多语言 SEO，构建同步到 `docs/` 供 GitHub Pages）。

```sh
cd web
bun install
bun run dev               # 本地预览
bun run build             # 打包并同步到 ../docs（en + zh-Hans）
```

详见 [web/README.md](web/README.md)。

## 构建与开发

需要 Xcode、macOS 14+ SDK 与 Bun：

```sh
bun install
bun run dev               # 构建 Debug .app 并前台运行
bun run build             # 构建 Release .app、DMG、ZIP（不发布）
bun run release           # 签名、公证并发布 GitHub Release
bun run clean             # 清理构建产物
bun run check             # 检查 Swift Package 结构
```

`bun run dev` 会先编译并打包 `QLaunch Dev.app`，然后以前台方式启动它，因此终端仍会显示 AppKit / Metal 日志。Debug App 位于：

```text
build/DerivedData/Build/Products/Debug/QLaunch Dev.app
```

本地 Release 构建产物位于 `build/`：

```text
build/DerivedData/Build/Products/Release/QLaunch.app
build/QLaunch-<version>.dmg
build/QLaunch-<version>.zip
```

发布前可在 `.env` 配置：

```sh
MACOS_SIGNING_IDENTITY=Developer ID Application: Your Name (TEAMID)
APPLE_ID=your-apple-id@example.com
APPLE_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
APPLE_TEAM_ID=XXXXXXXXXX
QLAUNCHPAD_NOTARY_PROFILE=QLaunch-notary
GITHUB_REPOSITORY=qzrzz/QLaunch
```

`bun run release -- 1.0.1` 可指定版本号；每次 Release 构建会递增 `package.json` 中的 `buildNumber`。正式发布需要 Developer ID Application 证书、公证凭据和已登录的 `gh`。

## 架构

```
AppDelegate          NSPanel 生命周期、热键、状态栏、fade 展示
LaunchpadContainer   背景 + Metal 网格 + SwiftUI 覆盖层
DesktopBackground    CIGaussianBlur 壁纸
LaunchpadMetalView   图标 / 标签实例化绘制、DisplayLink 动画、翻页
AppStore             扫描结果、搜索、分页状态机、展示状态
```

后续可扩展：登录项、图标变更监听、持久化排序；建议继续保持 AppKit / SwiftUI / Metal 边界清晰。
