import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import { webpAssets } from "./build/webp-assets-vite-plugin";

const isCodexSeatbeltSandbox = process.env.CODEX_SANDBOX === "seatbelt";

/** 构建纯 Vite React SPA，客户端只发布 WebP 图片。 */
export default defineConfig({
  base: "./",
  build: {
    assetsInlineLimit: 0,
    // lightningcss 会错误压缩 backdrop-filter（去空格 + 丢掉标准属性）。
    // 本站 CSS 体量很小；关闭压缩后由 scripts/build.ts 做安全压缩与修复。
    cssMinify: false,
  },
  server: isCodexSeatbeltSandbox
    ? { watch: { useFsEvents: false, usePolling: true } }
    : undefined,
  plugins: [react(), webpAssets()],
});
