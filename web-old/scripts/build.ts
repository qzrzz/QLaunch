#!/usr/bin/env bun
import { $ } from "bun";
import chalk from "chalk";
import {
  existsSync,
  mkdirSync,
  rmSync,
  cpSync,
  writeFileSync,
  readFileSync,
  readdirSync,
} from "node:fs";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  SUPPORTED_LANGS,
  uiDictMap,
  type SupportedLang,
} from "../src/i18n/dict";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

/** web 项目根路径与目标 docs 目录路径 */
const WEB_DIR = resolve(__dirname, "..");
const DIST_DIR = resolve(WEB_DIR, "dist");
const DOCS_DIR = resolve(WEB_DIR, "../docs");

/** GitHub Pages 站点根（用于 hreflang）。 */
const SITE_ORIGIN = "https://qzrzz.github.io/QLaunch";

/**
 * 安全 CSS 压缩：去掉注释与多余空白，但保留 filter 函数之间的空格。
 *
 * 不可用 lightningcss minify：会把 `blur(18px) saturate(1.2)` 压成
 * `blur(18px)saturate(1.2)`，并丢掉未加前缀的 `backdrop-filter`。
 */
export function minifyCssSafely(css: string): string {
  let out = css.replace(/\/\*[\s\S]*?\*\//g, "");
  // 空白折叠（不拆 filter 函数参数之间的空格语义：先折叠再只裁剪分隔符两侧）
  out = out.replace(/\s+/g, " ");
  out = out.replace(/\s*([{}:;,>~+])\s*/g, "$1");
  out = out.replace(/;}/g, "}");
  // 兜底：若某处已无空格，补回 filter 函数之间的间隔
  out = out.replace(
    /\)(?=(?:blur|brightness|contrast|grayscale|hue-rotate|invert|opacity|saturate|sepia|drop-shadow)\()/g,
    ") ",
  );
  // 同一规则内仅有 -webkit-backdrop-filter 时补标准属性（兼容 Firefox）
  out = ensureStandardBackdropFilter(out);
  return out.trim();
}

/** 在缺少标准 `backdrop-filter` 的规则块中，从 `-webkit-` 声明补一份。 */
export function ensureStandardBackdropFilter(css: string): string {
  return css.replace(
    /-webkit-backdrop-filter:([^;{}]+)/g,
    (full, value: string, offset: number, whole: string) => {
      const before = whole.slice(0, offset);
      const after = whole.slice(offset);
      const blockStart = before.lastIndexOf("{");
      const blockEndRel = after.indexOf("}");
      if (blockStart < 0 || blockEndRel < 0) {
        return full;
      }
      const block = whole.slice(blockStart, offset + blockEndRel + 1);
      if (/(?<!-webkit-)backdrop-filter:/.test(block)) {
        return full;
      }
      return `${full};backdrop-filter:${value}`;
    },
  );
}

/** 压缩 dist 内全部 CSS，并校验毛玻璃关键声明仍合法。 */
export function minifyDistCss(distDir: string): void {
  const assetsDir = join(distDir, "assets");
  if (!existsSync(assetsDir)) return;

  for (const name of readdirSync(assetsDir)) {
    if (!name.endsWith(".css")) continue;
    const path = join(assetsDir, name);
    const raw = readFileSync(path, "utf-8");
    const minified = minifyCssSafely(raw);
    writeFileSync(path, minified, "utf-8");

    // 构建失败应尽早暴露，避免再次把坏 CSS 同步进 docs
    const broken = minified.match(
      /backdrop-filter:[^;{}]*\)(?=(?:blur|brightness|contrast|grayscale|hue-rotate|invert|opacity|saturate|sepia)\()/i,
    );
    if (broken) {
      throw new Error(
        `CSS 压缩后 backdrop-filter 函数间缺少空格 (${name}): ${broken[0]}…`,
      );
    }
    if (
      minified.includes("backdrop-filter:") &&
      !minified.includes("backdrop-filter:blur") &&
      !minified.includes("backdrop-filter: blur") &&
      !/-webkit-backdrop-filter:[^;]*blur/.test(minified) &&
      !/backdrop-filter:[^;]*blur/.test(minified)
    ) {
      // 有属性但无 blur 时不强制失败（可能是其他 filter）
    }
    const hasWebkit = /-webkit-backdrop-filter:\s*blur\(/.test(minified);
    const hasStandard = /(?<!-webkit-)backdrop-filter:\s*blur\(/.test(minified);
    if (hasWebkit && !hasStandard) {
      throw new Error(
        `CSS 缺少标准 backdrop-filter（仅有 -webkit-）: ${name}`,
      );
    }
  }
}

const DOWNLOAD_JSON_NAME = "download.json";

/** 官网构建会清空 docs，先读出已发布的 download.json，避免丢掉直链安装包信息。 */
function readPreservedDownloadJson(docsDir: string): string | null {
  const path = join(docsDir, DOWNLOAD_JSON_NAME);
  if (!existsSync(path)) return null;
  try {
    return readFileSync(path, "utf-8");
  } catch {
    return null;
  }
}

/** 若 Vite public 未带上 download.json，把构建前的清单写回 docs。 */
function restoreDownloadJson(docsDir: string, preserved: string | null): void {
  const path = join(docsDir, DOWNLOAD_JSON_NAME);
  if (existsSync(path) || !preserved) return;
  writeFileSync(path, preserved, "utf-8");
  console.log(chalk.green(`✔ 已保留官网下载清单: ${chalk.gray("docs/download.json")}`));
}

/**
 * 清空指定的目录内容。如果目录不存在则重新创建空目录。
 */
export function cleanDirectory(dirPath: string): void {
  if (existsSync(dirPath)) {
    rmSync(dirPath, { recursive: true, force: true });
  }
  mkdirSync(dirPath, { recursive: true });
}

/**
 * 递归复制源目录下的所有内容到目标目录。
 */
export function copyDirectoryContents(srcDir: string, destDir: string): void {
  if (!existsSync(srcDir)) {
    throw new Error(`源目录不存在: ${srcDir}`);
  }
  cpSync(srcDir, destDir, { recursive: true });
}

/**
 * 生成多语言 SEO 静态 HTML。
 */
function generateSeoHtml(templateHtml: string, lang: SupportedLang): string {
  const dict = uiDictMap[lang] || uiDictMap.en;
  const htmlLang = lang === "zh-Hans" ? "zh-Hans" : "en";
  const title = escapeHtml(dict.siteTitle);
  const desc = escapeHtml(dict.metaDesc);

  let html = templateHtml.replace(/<html lang="[^"]*"/, `<html lang="${htmlLang}"`);
  html = html.replace(/<title>.*?<\/title>/, `<title>${title}</title>`);
  html = html.replace(
    /<meta\s+name="description"\s+content="[^"]*"\s*\/?>/,
    `<meta name="description" content="${desc}" />`,
  );
  html = html.replace(
    /<meta\s+property="og:title"\s+content="[^"]*"\s*\/?>/,
    `<meta property="og:title" content="${title}" />`,
  );
  html = html.replace(
    /<meta\s+property="og:description"\s+content="[^"]*"\s*\/?>/,
    `<meta property="og:description" content="${desc}" />`,
  );

  const seoHeadTags = `
    <link rel="alternate" hreflang="en" href="${SITE_ORIGIN}/" />
    <link rel="alternate" hreflang="zh-Hans" href="${SITE_ORIGIN}/zh-Hans/" />
    <link rel="alternate" hreflang="x-default" href="${SITE_ORIGIN}/" />
  `;

  html = html.replace("</head>", `${seoHeadTags}\n  </head>`);

  // 子目录页面：相对静态资源改为 ../
  if (lang !== "en") {
    html = html.replaceAll('="./', '="../');
    html = html.replaceAll('src="./', 'src="../');
    html = html.replaceAll('href="./', 'href="../');
  }

  return html;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

/**
 * 构建 Vite 产物，生成多语言 SEO 页并同步到 GitHub Pages docs。
 */
export async function buildAndPublishDocs(): Promise<void> {
  console.log(chalk.bold.cyan("\n🚀 开始构建 QLaunch Web 多语言官网...\n"));

  console.log(chalk.blue("📦 步骤 1/6: 正在执行 Vite 打包构建..."));
  try {
    await $`bunx vite build`.cwd(WEB_DIR);
    console.log(chalk.green("✔ Vite 构建成功完成！\n"));
  } catch (error) {
    console.error(chalk.red("✖ Vite 构建发生错误："), error);
    process.exit(1);
  }

  console.log(chalk.blue("🎨 步骤 2/6: 安全压缩 CSS（保留 backdrop-filter）..."));
  try {
    minifyDistCss(DIST_DIR);
    console.log(chalk.green("✔ CSS 压缩完成\n"));
  } catch (error) {
    console.error(chalk.red("✖ CSS 压缩/校验失败："), error);
    process.exit(1);
  }

  console.log(chalk.blue("🧹 步骤 3/6: 正在清空 ../docs 目录..."));
  const preservedDownloadJson = readPreservedDownloadJson(DOCS_DIR);
  cleanDirectory(DOCS_DIR);
  console.log(chalk.green(`✔ 已成功清空: ${chalk.gray(DOCS_DIR)}\n`));

  console.log(chalk.blue("📋 步骤 4/6: 复制构建产物至 ../docs 目录..."));
  copyDirectoryContents(DIST_DIR, DOCS_DIR);
  console.log(chalk.green("✔ 内容复制完成\n"));

  console.log(
    chalk.blue(
      `🌐 步骤 5/6: 生成多语言 SEO 静态页 (${SUPPORTED_LANGS.join(", ")})...`,
    ),
  );
  const templateHtmlPath = resolve(DOCS_DIR, "index.html");
  const templateHtml = readFileSync(templateHtmlPath, "utf-8");

  for (const lang of SUPPORTED_LANGS) {
    const seoHtml = generateSeoHtml(templateHtml, lang);

    if (lang === "en") {
      writeFileSync(templateHtmlPath, seoHtml);
      console.log(
        chalk.green(`  ✔ 默认/英文: ${chalk.gray("docs/index.html")}`),
      );
    } else {
      const langDir = resolve(DOCS_DIR, lang);
      mkdirSync(langDir, { recursive: true });
      writeFileSync(resolve(langDir, "index.html"), seoHtml);
      console.log(
        chalk.green(`  ✔ ${lang}: ${chalk.gray(`docs/${lang}/index.html`)}`),
      );
    }
  }

  console.log(chalk.blue("\n⚙️  步骤 6/6: 创建 GitHub Pages .nojekyll 文件..."));
  writeFileSync(resolve(DOCS_DIR, ".nojekyll"), "");
  restoreDownloadJson(DOCS_DIR, preservedDownloadJson);
  console.log(chalk.green("✔ 已生成 .nojekyll 文件\n"));

  console.log(
    chalk.bold.bgGreen.black(" 🎉 QLaunch Web 多语言构建及 docs 同步完成！ ") +
      "\n",
  );
}

if (import.meta.main) {
  buildAndPublishDocs();
}
