# QLaunch Web

QLaunch 的产品官网，使用 Vite、React 与 TypeScript 构建。  
架构与 QCopy/web 一致：`Feature/` 分区、`i18n` 多语言、`scripts/build.ts` 发布到 `../docs`。

## 开发

```bash
cd web
bun install
bun run dev
```

## 构建 / 发布到 GitHub Pages

```bash
bun run build
```

会执行 Vite 打包，生成 **en / zh-Hans** SEO 页，并同步到仓库根目录 `docs/`：

- `docs/index.html` — 英文（默认）
- `docs/zh-Hans/index.html` — 简体中文

## 多语言

| 能力 | 说明 |
|------|------|
| 路径 | `/` 英文，`/zh-Hans/` 中文 |
| 自动跳转 | 根路径按 localStorage / 浏览器语言跳到 zh-Hans |
| 切换器 | 顶栏语言下拉，写入 `qlaunchpad_lang` |
| 文案 | `src/i18n/dict.ts`（壳层）+ `src/content.ts`（分区） |

## 目录

- `src/content.ts`：分区内容（en / zh-Hans）
- `src/i18n/dict.ts`：UI 文案与语言工具
- `src/components/`：FeatureSection / FeatureCard / LanguageSwitcher
- `src/Feature/`：Header / Hero / Footer
- `src/shots/`：营销截图（源文件可 PNG；生产构建转 WebP）
- `build/webp-assets-vite-plugin.ts`：生产构建将 jpeg/png/svg 转无损 WebP 并改写引用
- `scripts/build.ts`：构建 + 多语言 SEO + 同步 docs

## 如何改内容

1. **壳层文案**：`src/i18n/dict.ts` 的 `uiDictMap`
2. **分区**：`src/content.ts` 的 `sectionsContentMap`

```ts
{ image: transfer, style: "center" } // left | right | bottom | center
```
