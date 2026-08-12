#!/usr/bin/env bun

import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { basename, join } from "node:path";
import {
  buildApp,
  captureCommand,
  runCommand,
} from "./build-app";
import {
  isSemVer,
  syncVersionAndBumpBuildNumber,
} from "./version";

const ROOT_DIR = join(import.meta.dir, "..");
const DEFAULT_NOTARY_PROFILE = "QLaunchpad-notary";
const DEFAULT_GITHUB_REPOSITORY = "qzrzz/QLaunchpad";

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

  const zipPath = join(ROOT_DIR, "build/QLaunchpad-" + version + "-notary.zip");
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
        "--volname", "QLaunchpad",
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
      "hdiutil", "create", "-volname", "QLaunchpad", "-srcfolder", stage,
      "-ov", "-format", "UDZO", dmgPath,
    ]);
  } finally {
    rmSync(stage, { recursive: true, force: true });
  }
}

function releaseNotes(version: string): string {
  const changelogPath = join(ROOT_DIR, "CHANGELOG.md");
  if (!existsSync(changelogPath)) {
    return "QLaunchpad " + version + "\n\nQLaunchpad macOS release.";
  }

  const sections = readFileSync(changelogPath, "utf8").split(/^##\s+/m).slice(1);
  const target = sections.find((section) => section.startsWith("[" + version + "]") || section.startsWith(version));
  if (target) return target.trim();
  return sections[0]?.trim() || ("QLaunchpad " + version);
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
  let exists = false;
  try {
    await captureCommand(["gh", "release", "view", tag, "--repo", repository]);
    exists = true;
  } catch {
    // Release does not exist yet.
  }

  if (exists) {
    await runCommand([
      "gh", "release", "edit", tag, "--repo", repository,
      "--title", "QLaunchpad " + tag,
      "--notes-file", notesPath,
    ]);
  } else {
    await runCommand([
      "gh", "release", "create", tag, "--repo", repository,
      "--title", "QLaunchpad " + tag,
      "--notes-file", notesPath,
    ]);
  }

  for (const asset of assets) {
    console.log("▸ 上传 " + basename(asset) + "…");
    await runCommand(["gh", "release", "upload", tag, asset, "--repo", repository, "--clobber"]);
  }
  console.log("✓ GitHub Release 已发布: " + tag);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const noPublish = args.includes("--no-publish");
  const versionArgs = args.filter((arg) => arg !== "--no-publish");
  if (versionArgs.length > 1 || versionArgs[0]?.startsWith("--")) {
    throw new Error("用法: bun scripts/release.ts [X.Y.Z] [--no-publish]");
  }
  const versionOverride = versionArgs[0];
  if (versionOverride && !isSemVer(versionOverride)) {
    throw new Error("版本号必须是 X.Y.Z: " + versionOverride);
  }

  const env = loadEnv();
  const { version, buildNumber } = syncVersionAndBumpBuildNumber(versionOverride);
  const publishing = !noPublish;
  console.log("\n📦 QLaunchpad " + (publishing ? "发布" : "本地构建") + "流程");
  console.log("▸ 版本: " + version + " | Build: " + buildNumber);

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
    productName: "QLaunchpad",
    bundleIdentifier: "com.qzrzz.qlaunchpad",
    signIdentity: identity,
  });

  let notarized = false;
  if (developerID) {
    notarized = await notarizeApp(app.appPath, version, env);
  }
  if (publishing && !notarized) {
    throw new Error("发布流程未完成公证，请配置 QLaunchpad-notary profile 或 Apple 公证凭据");
  }

  const dmgPath = join(ROOT_DIR, "build/QLaunchpad-" + version + ".dmg");
  const zipPath = join(ROOT_DIR, "build/QLaunchpad-" + version + ".zip");
  const notesPath = join(ROOT_DIR, "build/QLaunchpad-" + version + ".md");
  await createDMG(app.appPath, dmgPath);
  rmSync(zipPath, { force: true });
  await runCommand(["ditto", "-c", "-k", "--keepParent", app.appPath, zipPath]);
  mkdirSync(join(ROOT_DIR, "build"), { recursive: true });
  writeFileSync(notesPath, releaseNotes(version) + "\n", "utf8");

  console.log("\n✓ 本地构建完成");
  console.log("  App: " + app.appPath);
  console.log("  DMG: " + dmgPath);
  console.log("  ZIP: " + zipPath);
  console.log("  Notes: " + notesPath);
  console.log("  签名: " + identity + " | 公证: " + (notarized ? "是" : "否"));

  if (publishing) {
    await publishToGitHub(version, [dmgPath, zipPath, notesPath], notesPath, env);
  } else {
    console.log("ℹ️ 已跳过 GitHub Release 发布");
  }
}

main().catch((error) => {
  console.error("\n✗ " + (error instanceof Error ? error.message : error));
  process.exit(1);
});
