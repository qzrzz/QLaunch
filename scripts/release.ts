#!/usr/bin/env bun

/**
 * QLaunch 发布流程（自动更新对齐 QCopy / Qjiao）：
 * 1. 同步 package.json 版本并递增 buildNumber
 * 2. Release 编译 + 嵌入 Sparkle.framework + Developer ID 签名
 * 3. notarize + staple
 * 4. 生成 QLaunch-<version>.dmg（新用户安装）
 * 5. 基于本机 release/ 历史做 delta，调用 generate_appcast 写出 appcast.xml
 * 6. 上传 GitHub Release：DMG、ZIP、notes、appcast、delta
 * 7. 写出 web/download.json 与 docs/download.json，供官网直链安装包
 *
 * 应用检查更新的 feed：
 *   https://github.com/qzrzz/QLaunch/releases/latest/download/appcast.xml
 *
 * 依赖 .env：
 *   MACOS_SIGNING_IDENTITY / APPLE_* / QLAUNCHPAD_NOTARY_PROFILE
 *   SPARKLE_ACCOUNT            Keychain 账户（默认 qjiao，与内置公钥一致）
 *   SPARKLE_PRIVATE_KEY_FILE   可选，私钥备份文件；默认读钥匙串
 *   SPARKLE_BIN / SPARKLE_BIN_DIR  可选，generate_appcast 所在 bin
 *
 * 用法:
 *   bun scripts/release.ts [X.Y.Z]
 *   bun scripts/release.ts [X.Y.Z] --no-publish
 *   bun scripts/release.ts [X.Y.Z] --publish-only
 */

import {
  constants as fsConstants,
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { basename, join } from "node:path";
import {
  SPARKLE_FEED_URL,
  SPARKLE_PUBLIC_ED_KEY,
  buildApp,
  captureCommand,
  runCommand,
} from "./build-app";
import {
  createFileSha256,
  ensureDownloadManifest,
  writeDownloadManifest,
} from "./download-json";
import { generateAppcast } from "./generate-appcast";
import {
  isSemVer,
  readBuildNumber,
  readPackageVersion,
  syncVersionAndBumpBuildNumber,
} from "./version";

const ROOT_DIR = join(import.meta.dir, "..");
const DEFAULT_NOTARY_PROFILE = "QLaunch-notary";
const DEFAULT_GITHUB_REPOSITORY = "qzrzz/QLaunch";
const ARTIFACT_PREFIX = "QLaunch";
const UPDATES_DIR = join(ROOT_DIR, "build/updates");
const RELEASE_CACHE_DIR = process.env.RELEASE_CACHE_DIR ?? join(ROOT_DIR, "release");
const RELEASE_CACHE_ARCHIVES_DIR = join(RELEASE_CACHE_DIR, "archives");
const RELEASE_CACHE_APPCAST_PATH = join(RELEASE_CACHE_DIR, "appcast.xml");
const RELEASE_CACHE_MANIFEST_PATH = join(RELEASE_CACHE_DIR, "manifest.json");
const MAX_DELTA_BASELINES = 3;

interface ReleaseCacheEntry {
  version: string;
  build: string;
  tag: string;
  archiveName: string;
  sha256: string;
  size: number;
  publishedAt: string;
}

interface ReleaseCacheManifest {
  schemaVersion: 1;
  entries: ReleaseCacheEntry[];
}

function loadEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(Bun.env)) {
    if (value !== undefined) env[key] = value;
  }

  const envPath = join(ROOT_DIR, ".env");
  if (!existsSync(envPath)) return env;
  for (const line of readFileSync(envPath, "utf8").split("\n")) {
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (match && env[match[1]] === undefined) {
      env[match[1]] = match[2].replace(/^['"]|['"]$/g, "");
    }
  }
  return env;
}

async function resolveSigningIdentity(env: Record<string, string>): Promise<string> {
  if (env.MACOS_SIGNING_IDENTITY?.trim()) {
    return env.MACOS_SIGNING_IDENTITY.trim();
  }
  try {
    const identities = await captureCommand(["security", "find-identity", "-p", "codesigning"]);
    return identities.match(/"([^\"]*Developer ID Application[^\"]*)"/)?.[1] ?? "-";
  } catch {
    return "-";
  }
}

async function hasNotaryProfile(profile: string): Promise<boolean> {
  try {
    await captureCommand(["xcrun", "notarytool", "history", "--keychain-profile", profile]);
    return true;
  } catch {
    return false;
  }
}

async function configureNotaryProfile(env: Record<string, string>): Promise<string | null> {
  const profile = env.QLAUNCHPAD_NOTARY_PROFILE?.trim() || DEFAULT_NOTARY_PROFILE;
  if (await hasNotaryProfile(profile)) return profile;

  const appleID = env.APPLE_ID;
  const password = env.APPLE_APP_SPECIFIC_PASSWORD;
  const teamID = env.APPLE_TEAM_ID;
  if (!appleID || !password || !teamID) return null;

  console.log("▸ 写入公证凭据到钥匙串 profile: " + profile + "…");
  try {
    await runCommand([
      "xcrun", "notarytool", "store-credentials", profile,
      "--apple-id", appleID,
      "--team-id", teamID,
      "--password", password,
    ]);
  } catch {
    return null;
  }
  return (await hasNotaryProfile(profile)) ? profile : null;
}

async function notarizeApp(appPath: string, version: string, env: Record<string, string>): Promise<boolean> {
  const profile = await configureNotaryProfile(env);
  if (!profile) {
    console.warn("⚠️ 未找到公证凭据，跳过 notarize");
    return false;
  }

  const zipPath = join(ROOT_DIR, "build/QLaunch-" + version + "-notary.zip");
  console.log("▸ 压缩 App 并提交 Apple 公证…");
  rmSync(zipPath, { force: true });
  await runCommand(["ditto", "-c", "-k", "--keepParent", appPath, zipPath]);
  try {
    await runCommand(["xcrun", "notarytool", "submit", zipPath, "--keychain-profile", profile, "--wait"]);
    console.log("▸ 装订公证凭据…");
    await runCommand(["xcrun", "stapler", "staple", appPath]);
    return true;
  } finally {
    rmSync(zipPath, { force: true });
  }
}

async function createDMG(appPath: string, dmgPath: string): Promise<void> {
  rmSync(dmgPath, { force: true });
  const createDmg = Bun.which("create-dmg");
  if (createDmg) {
    try {
      console.log("▸ 使用 create-dmg 打包安装镜像…");
      await runCommand([
        createDmg,
        "--volname", "QLaunch",
        "--window-pos", "200", "120",
        "--window-size", "600", "400",
        "--icon-size", "128",
        "--icon", basename(appPath), "160", "190",
        "--app-drop-link", "440", "190",
        "--hide-extension", basename(appPath),
        "--overwrite", dmgPath, appPath,
      ]);
      return;
    } catch (error) {
      console.warn("⚠️ create-dmg 失败，改用 hdiutil: " + (error instanceof Error ? error.message : error));
    }
  }

  console.log("▸ 使用 hdiutil 打包安装镜像…");
  const stage = await captureCommand(["mktemp", "-d"]);
  try {
    await runCommand(["cp", "-R", appPath, join(stage, basename(appPath))]);
    await runCommand(["ln", "-s", "/Applications", join(stage, "Applications")]);
    await runCommand([
      "hdiutil", "create", "-volname", "QLaunch", "-srcfolder", stage,
      "-ov", "-format", "UDZO", dmgPath,
    ]);
  } finally {
    rmSync(stage, { recursive: true, force: true });
  }
}

function isValidSparklePublicKey(value: string): boolean {
  return /^[A-Za-z0-9+/]{40,60}={0,2}$/.test(value) && !value.includes("REPLACE");
}

function requireSparklePublicKey(): string {
  if (!isValidSparklePublicKey(SPARKLE_PUBLIC_ED_KEY)) {
    throw new Error(
      "SUPublicEDKey 无效。请设置 SPARKLE_PUBLIC_ED_KEY，或确认与钥匙串 SPARKLE_ACCOUNT 对应。",
    );
  }
  return SPARKLE_PUBLIC_ED_KEY;
}

function releaseNotes(version: string): string {
  const changelogPath = join(ROOT_DIR, "CHANGELOG.md");
  if (!existsSync(changelogPath)) {
    return "QLaunch " + version + "\n\nQLaunch macOS release.";
  }

  const sections = readFileSync(changelogPath, "utf8").split(/^##\s+/m).slice(1);
  const target = sections.find((section) => section.startsWith("[" + version + "]") || section.startsWith(version));
  if (target) return target.trim();
  return sections[0]?.trim() || ("QLaunch " + version);
}

function copyFileAtomically(source: string, destination: string): void {
  const temporaryPath = destination + "." + process.pid + ".tmp";
  rmSync(temporaryPath, { force: true });
  try {
    copyFileSync(source, temporaryPath, fsConstants.COPYFILE_FICLONE);
    renameSync(temporaryPath, destination);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

function readReleaseCacheManifest(): ReleaseCacheManifest {
  if (!existsSync(RELEASE_CACHE_MANIFEST_PATH)) {
    return { schemaVersion: 1, entries: [] };
  }
  try {
    const value = JSON.parse(readFileSync(RELEASE_CACHE_MANIFEST_PATH, "utf8")) as {
      schemaVersion?: unknown;
      entries?: unknown;
    };
    if (value.schemaVersion !== 1 || !Array.isArray(value.entries)) {
      throw new Error("unsupported schema");
    }
    const entries = value.entries.filter(isReleaseCacheEntry);
    return { schemaVersion: 1, entries };
  } catch {
    console.warn("⚠️ 忽略损坏的 release 缓存清单: " + RELEASE_CACHE_MANIFEST_PATH);
    return { schemaVersion: 1, entries: [] };
  }
}

function isReleaseCacheEntry(value: unknown): value is ReleaseCacheEntry {
  if (!value || typeof value !== "object") return false;
  const entry = value as Partial<ReleaseCacheEntry>;
  return (
    typeof entry.version === "string" &&
    entry.version.length > 0 &&
    typeof entry.build === "string" &&
    /^[1-9][0-9]*$/.test(entry.build) &&
    typeof entry.tag === "string" &&
    typeof entry.archiveName === "string" &&
    basename(entry.archiveName) === entry.archiveName &&
    entry.archiveName.endsWith(".zip") &&
    typeof entry.sha256 === "string" &&
    /^[a-f0-9]{64}$/.test(entry.sha256) &&
    typeof entry.size === "number" &&
    Number.isSafeInteger(entry.size) &&
    entry.size > 0 &&
    typeof entry.publishedAt === "string" &&
    Number.isFinite(Date.parse(entry.publishedAt))
  );
}

async function validateReleaseCacheEntry(entry: ReleaseCacheEntry): Promise<boolean> {
  const path = join(RELEASE_CACHE_ARCHIVES_DIR, entry.archiveName);
  return (
    existsSync(path) &&
    Bun.file(path).size === entry.size &&
    (await createFileSha256(path)) === entry.sha256
  );
}

function assertBuildIsNewerThanCache(build: string, version: string): void {
  const cachedBuilds = readReleaseCacheManifest().entries.map((entry) => BigInt(entry.build));
  if (cachedBuilds.length === 0) return;
  const latestBuild = cachedBuilds.reduce((left, right) => (right > left ? right : left));
  if (BigInt(build) <= latestBuild) {
    throw new Error(
      "build " + build + " 不大于本地缓存的 build " + latestBuild +
        "；发布 " + version + " 前请确认 package.json buildNumber 已递增",
    );
  }
}

async function prepareLocalDeltaBaselines(
  currentBuild: string,
  appcastPath: string,
): Promise<void> {
  const manifest = readReleaseCacheManifest();
  if (existsSync(RELEASE_CACHE_APPCAST_PATH) && Bun.file(RELEASE_CACHE_APPCAST_PATH).size > 0) {
    copyFileAtomically(RELEASE_CACHE_APPCAST_PATH, appcastPath);
    console.log("▸ 使用本地 Sparkle 历史: " + RELEASE_CACHE_APPCAST_PATH);
  }

  const candidates = manifest.entries
    .filter((entry) => entry.build !== currentBuild)
    .sort((left, right) => Date.parse(right.publishedAt) - Date.parse(left.publishedAt))
    .slice(0, MAX_DELTA_BASELINES);

  let copied = 0;
  for (const entry of candidates) {
    if (!(await validateReleaseCacheEntry(entry))) {
      console.warn("⚠️ 忽略无效 delta 基线 " + entry.archiveName);
      continue;
    }
    copyFileAtomically(
      join(RELEASE_CACHE_ARCHIVES_DIR, entry.archiveName),
      join(UPDATES_DIR, entry.archiveName),
    );
    copied += 1;
    console.log(
      "▸ delta 基线 " + copied + "/" + MAX_DELTA_BASELINES +
        ": " + entry.archiveName + " (build " + entry.build + ")",
    );
  }
  if (copied === 0) {
    console.log("▸ 无有效本地基线，仅生成完整 ZIP 更新");
  }
}

async function normalizeAppcastArchiveUrls(
  path: string,
  repository: string,
): Promise<void> {
  const original = readFileSync(path, "utf8");
  const normalized = original.replace(/<item>[\s\S]*?<\/item>/g, (item): string => {
    const version = item.match(
      /<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/,
    )?.[1];
    if (!version || !/^[0-9A-Za-z.+-]+$/.test(version)) return item;
    const archiveUrl =
      "https://github.com/" + repository + "/releases/download/" +
      "v" + version + "/" + ARTIFACT_PREFIX + "-" + version + ".zip";
    return item
      .replace(/<title>[^<]*<\/title>/, "<title>" + version + "</title>")
      .replace(/(<enclosure\s+url=")[^"]+\.zip(")/, "$1" + archiveUrl + "$2");
  });
  if (normalized !== original) {
    await Bun.write(path, normalized);
  }
}

async function writeReleaseCacheManifest(manifest: ReleaseCacheManifest): Promise<void> {
  mkdirSync(RELEASE_CACHE_DIR, { recursive: true });
  const temporaryPath = RELEASE_CACHE_MANIFEST_PATH + "." + process.pid + ".tmp";
  try {
    await Bun.write(temporaryPath, JSON.stringify(manifest, null, 2) + "\n");
    renameSync(temporaryPath, RELEASE_CACHE_MANIFEST_PATH);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

async function persistReleaseCache(
  version: string,
  build: string,
  tag: string,
  zipPath: string,
  appcastPath: string,
): Promise<void> {
  if (!existsSync(zipPath) || Bun.file(zipPath).size === 0) {
    throw new Error("无法缓存不完整的 Sparkle ZIP");
  }
  if (!existsSync(appcastPath) || Bun.file(appcastPath).size === 0) {
    throw new Error("无法缓存不完整的 appcast");
  }

  mkdirSync(RELEASE_CACHE_ARCHIVES_DIR, { recursive: true });
  const archiveName = basename(zipPath);
  const entry: ReleaseCacheEntry = {
    version,
    build,
    tag,
    archiveName,
    sha256: await createFileSha256(zipPath),
    size: Bun.file(zipPath).size,
    publishedAt: new Date().toISOString(),
  };

  copyFileAtomically(zipPath, join(RELEASE_CACHE_ARCHIVES_DIR, archiveName));
  if (!(await validateReleaseCacheEntry(entry))) {
    throw new Error("缓存 ZIP 校验失败: " + archiveName);
  }
  copyFileAtomically(appcastPath, RELEASE_CACHE_APPCAST_PATH);

  const previous = readReleaseCacheManifest();
  const entries = [
    entry,
    ...previous.entries.filter(
      (cached) => cached.build !== entry.build && cached.archiveName !== entry.archiveName,
    ),
  ]
    .sort((left, right) => Date.parse(right.publishedAt) - Date.parse(left.publishedAt))
    .slice(0, MAX_DELTA_BASELINES);
  await writeReleaseCacheManifest({ schemaVersion: 1, entries });

  const kept = new Set(entries.map((cached) => cached.archiveName));
  for (const name of readdirSync(RELEASE_CACHE_ARCHIVES_DIR)) {
    if (
      name.startsWith(ARTIFACT_PREFIX + "-") &&
      name.endsWith(".zip") &&
      !kept.has(name)
    ) {
      rmSync(join(RELEASE_CACHE_ARCHIVES_DIR, name), { force: true });
    }
  }
  console.log(
    "▸ 已写入本地 Sparkle 历史 " + RELEASE_CACHE_DIR +
      "（" + entries.length + "/" + MAX_DELTA_BASELINES + " 版）",
  );
}

function listGeneratedDeltaPaths(): string[] {
  if (!existsSync(UPDATES_DIR)) return [];
  return readdirSync(UPDATES_DIR)
    .filter((name) => name.endsWith(".delta"))
    .sort()
    .map((name) => join(UPDATES_DIR, name));
}

async function generateSparkleUpdates(options: {
  appPath: string;
  version: string;
  buildNumber: string;
  notes: string;
  env: Record<string, string>;
  repository: string;
  sign: boolean;
}): Promise<{ zipPath: string; notesPath: string; appcastPath: string }> {
  const { appPath, version, buildNumber, notes, env, repository, sign } = options;
  const tag = "v" + version;
  const zipName = ARTIFACT_PREFIX + "-" + version + ".zip";
  const notesName = ARTIFACT_PREFIX + "-" + version + ".md";
  const zipPath = join(UPDATES_DIR, zipName);
  const notesPath = join(UPDATES_DIR, notesName);
  const appcastPath = join(UPDATES_DIR, "appcast.xml");

  if (sign) {
    assertBuildIsNewerThanCache(buildNumber, version);
  }

  rmSync(UPDATES_DIR, { recursive: true, force: true });
  mkdirSync(UPDATES_DIR, { recursive: true });

  if (sign && env.NO_HISTORY !== "1") {
    await prepareLocalDeltaBaselines(buildNumber, appcastPath);
  }

  console.log("▸ 生成 Sparkle 完整更新 ZIP…");
  await runCommand(["ditto", "-c", "-k", "--keepParent", appPath, zipPath]);
  writeFileSync(notesPath, notes + "\n", "utf8");

  if (sign) {
    const account = env.SPARKLE_ACCOUNT?.trim() || env.SPARKLE_KEY_ACCOUNT?.trim() || "qjiao";
    const privateKeyFile = env.SPARKLE_PRIVATE_KEY_FILE?.trim();
    if (privateKeyFile && !existsSync(privateKeyFile)) {
      throw new Error("SPARKLE_PRIVATE_KEY_FILE 指向的文件不存在");
    }

    console.log("▸ 调用 generate_appcast（签名 ZIP / 生成 delta / 更新 appcast）…");
    await generateAppcast(
      UPDATES_DIR,
      {
        downloadUrlPrefix: "https://github.com/" + repository + "/releases/download/" + tag + "/",
        edKeyFile: privateKeyFile,
        account,
        versions: [buildNumber],
      },
      ROOT_DIR,
    );
    await normalizeAppcastArchiveUrls(appcastPath, repository);
  } else {
    writeFileSync(
      appcastPath,
      "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
        "<!-- unsigned local appcast for " + version + " (build " + buildNumber + ") -->\n",
      "utf8",
    );
  }

  if (!existsSync(appcastPath)) {
    throw new Error("未生成 appcast: " + appcastPath);
  }
  return { zipPath, notesPath, appcastPath };
}

function isTransientNetworkError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /EOF|timeout|timed out|ECONNRESET|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|temporar|network|502|503|504|connection reset|TLS handshake|i\/o timeout/i
    .test(message);
}

async function sleep(ms: number): Promise<void> {
  await Bun.sleep(ms);
}

async function runGh(command: string[], attempts = 5): Promise<void> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      await runCommand(command);
      return;
    } catch (error) {
      lastError = error;
      if (!isTransientNetworkError(error) || attempt === attempts) throw error;
      const delay = 2000 * attempt;
      console.warn(
        "⚠️ GitHub 请求中断，" + delay / 1000 + "s 后重试 (" + attempt + "/" + attempts + "): " +
          command.join(" "),
      );
      await sleep(delay);
    }
  }
  throw lastError;
}

async function githubReleaseExists(tag: string, repository: string): Promise<boolean> {
  try {
    await captureCommand(["gh", "release", "view", tag, "--repo", repository]);
    return true;
  } catch {
    return false;
  }
}

function collectReleaseAssets(version: string): {
  dmgPath: string;
  zipPath: string;
  notesPath: string;
  appcastPath: string;
  assets: string[];
} {
  const dmgPath = join(ROOT_DIR, "build/QLaunch-" + version + ".dmg");
  const zipPath = join(UPDATES_DIR, ARTIFACT_PREFIX + "-" + version + ".zip");
  const notesPath = join(UPDATES_DIR, ARTIFACT_PREFIX + "-" + version + ".md");
  const appcastPath = join(UPDATES_DIR, "appcast.xml");
  const required = [dmgPath, zipPath, notesPath, appcastPath];
  const missing = required.filter((path) => !existsSync(path) || Bun.file(path).size === 0);
  if (missing.length > 0) {
    throw new Error("找不到已构建的发布产物:\n  " + missing.join("\n  "));
  }
  return {
    dmgPath,
    zipPath,
    notesPath,
    appcastPath,
    assets: [dmgPath, zipPath, notesPath, appcastPath, ...listGeneratedDeltaPaths()],
  };
}

async function publishToGitHub(
  version: string,
  assets: string[],
  notesPath: string,
  env: Record<string, string>,
): Promise<void> {
  if (!Bun.which("gh")) {
    throw new Error("未找到 gh，请先安装 GitHub CLI 并登录");
  }
  const repository = env.GITHUB_REPOSITORY || DEFAULT_GITHUB_REPOSITORY;
  const tag = "v" + version;

  if (await githubReleaseExists(tag, repository)) {
    console.log("▸ 更新已有 GitHub Release " + tag + "…");
    await runGh([
      "gh", "release", "edit", tag, "--repo", repository,
      "--title", "QLaunch " + tag,
      "--notes-file", notesPath,
    ]);
  } else {
    console.log("▸ 创建 GitHub Release " + tag + "…");
    try {
      await runGh([
        "gh", "release", "create", tag, "--repo", repository,
        "--title", "QLaunch " + tag,
        "--notes-file", notesPath,
      ]);
    } catch (error) {
      if (await githubReleaseExists(tag, repository)) {
        console.warn("⚠️ 创建时网络中断，但 Release 已存在，继续上传产物");
      } else {
        throw error;
      }
    }
  }

  for (const asset of assets) {
    console.log("▸ 上传 " + basename(asset) + "…");
    await runGh(["gh", "release", "upload", tag, asset, "--repo", repository, "--clobber"]);
  }
  console.log("✓ GitHub Release 已发布: " + tag);
  console.log("  Sparkle feed: " + SPARKLE_FEED_URL);
}

async function publishExistingBuild(
  version: string,
  buildNumber: string,
  env: Record<string, string>,
): Promise<void> {
  const repository = env.GITHUB_REPOSITORY || DEFAULT_GITHUB_REPOSITORY;
  const { dmgPath, zipPath, notesPath, appcastPath, assets } = collectReleaseAssets(version);
  console.log("\n📦 QLaunch 补发 GitHub Release");
  console.log("▸ 版本: " + version + " | Build: " + buildNumber);
  console.log("▸ Sparkle feed: " + SPARKLE_FEED_URL);
  console.log("  DMG: " + dmgPath);
  console.log("  Sparkle ZIP: " + zipPath);
  console.log("  appcast: " + appcastPath);

  await publishToGitHub(version, assets, notesPath, env);
  await persistReleaseCache(version, buildNumber, "v" + version, zipPath, appcastPath);
  await writeDownloadManifest({
    version,
    build: buildNumber,
    repository,
    dmgPath,
    zipPath,
  });
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const noPublish = args.includes("--no-publish");
  const publishOnly = args.includes("--publish-only");
  if (noPublish && publishOnly) {
    throw new Error("不能同时使用 --no-publish 与 --publish-only");
  }
  const versionArgs = args.filter((arg) => arg !== "--no-publish" && arg !== "--publish-only");
  if (versionArgs.length > 1 || versionArgs[0]?.startsWith("--")) {
    throw new Error("用法: bun scripts/release.ts [X.Y.Z] [--no-publish|--publish-only]");
  }
  const versionOverride = versionArgs[0];
  if (versionOverride && !isSemVer(versionOverride)) {
    throw new Error("版本号必须是 X.Y.Z: " + versionOverride);
  }

  const env = loadEnv();
  requireSparklePublicKey();
  const repository = env.GITHUB_REPOSITORY || DEFAULT_GITHUB_REPOSITORY;
  await ensureDownloadManifest(repository);

  if (publishOnly) {
    const version = versionOverride ?? readPackageVersion();
    const buildNumber = readBuildNumber();
    await publishExistingBuild(version, buildNumber, env);
    return;
  }

  const { version, buildNumber } = syncVersionAndBumpBuildNumber(versionOverride);
  const publishing = !noPublish;
  console.log("\n📦 QLaunch " + (publishing ? "发布" : "本地构建") + "流程");
  console.log("▸ 版本: " + version + " | Build: " + buildNumber);
  console.log("▸ Sparkle feed: " + SPARKLE_FEED_URL);

  const identity = await resolveSigningIdentity(env);
  const developerID = identity.includes("Developer ID Application");
  console.log("▸ 签名身份: " + identity + (developerID ? "" : "（ad-hoc / 本地）"));
  if (publishing && !developerID) {
    throw new Error("正式发布需要 Developer ID Application；本地构建请使用 bun run build");
  }

  const app = await buildApp({
    configuration: "release",
    version,
    buildNumber,
    productName: "QLaunch",
    bundleIdentifier: "com.qzrzz.qlaunchpad",
    signIdentity: identity,
  });

  let notarized = false;
  if (developerID) {
    notarized = await notarizeApp(app.appPath, version, env);
  }
  if (publishing && !notarized) {
    throw new Error("发布流程未完成公证，请配置 QLaunch-notary profile 或 Apple 公证凭据");
  }

  const dmgPath = join(ROOT_DIR, "build/QLaunch-" + version + ".dmg");
  await createDMG(app.appPath, dmgPath);
  if (developerID && notarized) {
    try {
      await runCommand(["xcrun", "stapler", "staple", dmgPath]);
    } catch {
      console.warn("⚠️ DMG staple 失败（可稍后手动 stapler staple）");
    }
  }

  const notes = releaseNotes(version);
  const { zipPath, notesPath, appcastPath } = await generateSparkleUpdates({
    appPath: app.appPath,
    version,
    buildNumber,
    notes,
    env,
    repository,
    sign: publishing,
  });

  console.log("\n✓ 本地构建完成");
  console.log("  App: " + app.appPath);
  console.log("  DMG: " + dmgPath);
  console.log("  Sparkle ZIP: " + zipPath);
  console.log("  appcast: " + appcastPath);
  console.log("  Notes: " + notesPath);
  console.log("  签名: " + identity + " | 公证: " + (notarized ? "是" : "否"));

  if (publishing) {
    await publishToGitHub(
      version,
      [dmgPath, zipPath, notesPath, appcastPath, ...listGeneratedDeltaPaths()],
      notesPath,
      env,
    );
    await persistReleaseCache(version, buildNumber, "v" + version, zipPath, appcastPath);
    await writeDownloadManifest({
      version,
      build: buildNumber,
      repository,
      dmgPath,
      zipPath,
    });
  } else {
    console.log("ℹ️ 已跳过 GitHub Release、release/ 缓存与官网 download.json（--no-publish）");
  }
}

main().catch((error) => {
  console.error("\n✗ " + (error instanceof Error ? error.message : error));
  process.exit(1);
});
