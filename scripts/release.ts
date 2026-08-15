#!/usr/bin/env bun

/**
 * QLaunch 发布流程（自动更新对齐 QCopy / Qjiao）：
 * 1. 同步 package.json 版本并递增 buildNumber
 * 2. Release 编译 + 嵌入 Sparkle.framework + Developer ID 签名
 * 3. notarize + staple
 * 4. 生成 QLaunch-<version>.dmg（新用户安装）
 * 5. 基于本机 release/ 历史做 delta，调用 generate_appcast 写出 appcast.xml
 * 6. 用 QRls 发布到 R2（主源），默认同时镜像 GitHub Release；download.json 由 QRls 生成并上传
 *
 * 应用检查更新的 feed：
 *   https://download.qzrzz.com/qlaunch/appcast.xml
 *
 * 依赖 .env：
 *   MACOS_SIGNING_IDENTITY / APPLE_* / QLAUNCHPAD_NOTARY_PROFILE
 *   SPARKLE_ACCOUNT            Keychain 账户（默认 qjiao，与内置公钥一致）
 *   SPARKLE_PRIVATE_KEY_FILE   可选，私钥备份文件；默认读钥匙串
 *   SPARKLE_BIN / SPARKLE_BIN_DIR  可选，generate_appcast 所在 bin
 *   R2_ONLINE_URL / R2_BUCKET / R2_PATH  可选，覆盖 QRls R2 目标
 *   PUBLISH_GITHUB=0           只发 R2、不同步 GitHub
 *
 * 用法:
 *   bun scripts/release.ts [X.Y.Z]
 *   bun scripts/release.ts [X.Y.Z] --no-publish
 *   bun scripts/release.ts [X.Y.Z] --publish-only
 *   bun scripts/release.ts [X.Y.Z] --force
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
  SPARKLE_PUBLIC_ED_KEY,
  buildApp,
  captureCommand,
  runCommand,
} from "./build-app";
import { generateAppcast } from "./generate-appcast";
import {
  PUBLISH_GITHUB,
  R2_ONLINE_URL,
  SPARKLE_FEED_URL,
  publishWithQrls,
  r2PublicUrl,
} from "./qrls-publish";
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

async function createFileSha256(path: string): Promise<string> {
  const hash = new Bun.CryptoHasher("sha256");
  for await (const chunk of Bun.file(path).stream()) {
    hash.update(chunk);
  }
  return hash.digest("hex");
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

/** 读取本地 Sparkle 缓存里各历史版本的完整 ZIP 地址。 */
function readPreviousAppcastZipUrls(): Map<string, string> {
  const urls = new Map<string, string>();
  if (!existsSync(RELEASE_CACHE_APPCAST_PATH)) return urls;
  const previous = readFileSync(RELEASE_CACHE_APPCAST_PATH, "utf8");
  for (const match of previous.matchAll(/<item>[\s\S]*?<\/item>/g)) {
    const itemVersion = match[0].match(
      /<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/,
    )?.[1];
    const archiveUrl = match[0].match(/<enclosure\s+url="([^"]+\.zip)"/)?.[1];
    if (itemVersion && archiveUrl) urls.set(itemVersion, archiveUrl);
  }
  return urls;
}

/** 当前版本 ZIP 改写到 R2；历史 item 恢复 generate_appcast 之前的原始 URL。 */
async function normalizeAppcastArchiveUrls(path: string, version: string): Promise<void> {
  const original = readFileSync(path, "utf8");
  const previousZipByVersion = readPreviousAppcastZipUrls();
  const normalized = original.replace(/<item>[\s\S]*?<\/item>/g, (item): string => {
    const itemVersion = item.match(
      /<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/,
    )?.[1];
    if (!itemVersion || !/^[0-9A-Za-z.+-]+$/.test(itemVersion)) return item;
    const archiveUrl =
      itemVersion === version
        ? r2PublicUrl(ARTIFACT_PREFIX + "-" + itemVersion + ".zip")
        : previousZipByVersion.get(itemVersion);
    if (!archiveUrl) return item;
    return item
      .replace(/<title>[^<]*<\/title>/, "<title>" + itemVersion + "</title>")
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
  sign: boolean;
}): Promise<{ zipPath: string; notesPath: string; appcastPath: string }> {
  const { appPath, version, buildNumber, notes, env, sign } = options;
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
        downloadUrlPrefix: R2_ONLINE_URL + "/",
        edKeyFile: privateKeyFile,
        account,
        versions: [buildNumber],
      },
      ROOT_DIR,
    );
    await normalizeAppcastArchiveUrls(appcastPath, version);
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

function collectReleaseAssets(version: string): {
  dmgPath: string;
  zipPath: string;
  notesPath: string;
  appcastPath: string;
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
  return { dmgPath, zipPath, notesPath, appcastPath };
}

/**
 * 用 QRls 上传安装包：主发 R2，默认同时镜像 GitHub。
 */
async function publishWithQrlsRelease(options: {
  version: string;
  buildNumber: string;
  dmgPath: string;
  zipPath: string;
  notesPath: string;
  appcastPath: string;
  repository: string;
  changelog: string;
  force?: boolean;
}): Promise<void> {
  const {
    version,
    buildNumber,
    dmgPath,
    zipPath,
    notesPath,
    appcastPath,
    repository,
    changelog,
    force,
  } = options;
  const tag = "v" + version;
  console.log("▸ 用 QRls 发布 " + tag + " 到 R2（" + R2_ONLINE_URL + "）…");
  const qrlsResult = await publishWithQrls({
    name: ARTIFACT_PREFIX,
    version,
    build: buildNumber,
    repository,
    dmgPath,
    zipPath,
    notesPath,
    appcastPath,
    deltaPaths: listGeneratedDeltaPaths(),
    changelog,
    force,
    statePath: join(RELEASE_CACHE_DIR, ".qrls-state.json"),
  });
  if (qrlsResult.sparkle?.appcast) {
    await Bun.write(appcastPath, qrlsResult.sparkle.appcast);
  }
  console.log("✓ QRls 已发布: " + tag);
  console.log("  Sparkle feed: " + (qrlsResult.sparkle?.feedUrl ?? SPARKLE_FEED_URL));
  console.log("  download.json: " + r2PublicUrl("download.json"));
  if (PUBLISH_GITHUB) {
    console.log("  GitHub: https://github.com/" + repository + "/releases/tag/" + tag);
  }
}

async function publishExistingBuild(
  version: string,
  buildNumber: string,
  env: Record<string, string>,
  force = false,
): Promise<void> {
  const repository = env.GITHUB_REPOSITORY || DEFAULT_GITHUB_REPOSITORY;
  const { dmgPath, zipPath, notesPath, appcastPath } = collectReleaseAssets(version);
  const changelog = existsSync(notesPath) ? readFileSync(notesPath, "utf8") : "";
  console.log("\n📦 QLaunch 补发 QRls 发布");
  console.log("▸ 版本: " + version + " | Build: " + buildNumber);
  console.log("▸ Sparkle feed: " + SPARKLE_FEED_URL);
  console.log("  DMG: " + dmgPath);
  console.log("  Sparkle ZIP: " + zipPath);
  console.log("  appcast: " + appcastPath);

  await publishWithQrlsRelease({
    version,
    buildNumber,
    dmgPath,
    zipPath,
    notesPath,
    appcastPath,
    repository,
    changelog,
    force,
  });
  await persistReleaseCache(version, buildNumber, "v" + version, zipPath, appcastPath);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const noPublish = args.includes("--no-publish");
  const publishOnly = args.includes("--publish-only");
  const force = args.includes("--force");
  if (noPublish && publishOnly) {
    throw new Error("不能同时使用 --no-publish 与 --publish-only");
  }
  const versionArgs = args.filter(
    (arg) => arg !== "--no-publish" && arg !== "--publish-only" && arg !== "--force",
  );
  if (versionArgs.length > 1 || versionArgs[0]?.startsWith("--")) {
    throw new Error("用法: bun scripts/release.ts [X.Y.Z] [--no-publish|--publish-only] [--force]");
  }
  const versionOverride = versionArgs[0];
  if (versionOverride && !isSemVer(versionOverride)) {
    throw new Error("版本号必须是 X.Y.Z: " + versionOverride);
  }

  const env = loadEnv();
  requireSparklePublicKey();
  const repository = env.GITHUB_REPOSITORY || DEFAULT_GITHUB_REPOSITORY;

  if (publishOnly) {
    const version = versionOverride ?? readPackageVersion();
    const buildNumber = readBuildNumber();
    await publishExistingBuild(version, buildNumber, env, force);
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
    await publishWithQrlsRelease({
      version,
      buildNumber,
      dmgPath,
      zipPath,
      notesPath,
      appcastPath,
      repository,
      changelog: notes,
      force,
    });
    await persistReleaseCache(version, buildNumber, "v" + version, zipPath, appcastPath);
  } else {
    console.log("ℹ️ 已跳过 QRls 发布与 release/ 缓存（--no-publish）");
  }
}

main().catch((error) => {
  console.error("\n✗ " + (error instanceof Error ? error.message : error));
  process.exit(1);
});
