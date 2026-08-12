#!/usr/bin/env bun

import { createHash } from "node:crypto";
import {
  chmodSync,
  cpSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join, relative } from "node:path";

export type BuildConfiguration = "debug" | "release";

export interface AppBuildOptions {
  configuration: BuildConfiguration;
  version: string;
  buildNumber: string;
  productName?: string;
  bundleIdentifier?: string;
  signIdentity?: string;
}

export interface AppBuildResult {
  appPath: string;
  executablePath: string;
  configuration: BuildConfiguration;
  version: string;
  buildNumber: string;
}

const ROOT_DIR = join(import.meta.dir, "..");
const TARGET_NAME = "QLaunchpad";
const RESOURCE_BUNDLE_NAME = TARGET_NAME + "_" + TARGET_NAME + ".bundle";
/** Flat PNG fallback (About / `swift run` / actool unavailable). */
const ICON_PNG_SOURCE = join(ROOT_DIR, "Sources/QLaunchpad/Resources/QLaunchpadAppIcon.png");
/**
 * Icon Composer multi-layer source (preferred).
 * Override with env `QLAUNCHPAD_ICON` (path to a `.icon` package).
 */
const ICON_COMPOSER_CANDIDATES = [
  Bun.env.QLAUNCHPAD_ICON,
  join(ROOT_DIR, "icons/QLaunch.icon"),
  join(ROOT_DIR, "icons/AppIcon.icon"),
  join(ROOT_DIR, "icons/QLaunchpad.icon"),
].filter((value): value is string => Boolean(value));
/** Bundle icon base name → `QLaunch.icns` + `CFBundleIconName`. */
const BUNDLE_ICON_NAME = "QLaunch";
/** Compiled icon artifacts reused across `bun run dev` until the source changes. */
const ICON_CACHE_DIR = join(ROOT_DIR, "build/icon-cache");
const ICON_CACHE_MANIFEST = join(ICON_CACHE_DIR, "manifest.json");
const FORCE_ICON_REBUILD = Bun.env.QLAUNCHPAD_FORCE_ICON === "1";
const DEFAULT_SWIFT_MODULE_CACHE = "/private/tmp/qlaunchpad-swift-module-cache";
const DEFAULT_CLANG_MODULE_CACHE = "/private/tmp/qlaunchpad-clang-module-cache";

const commandEnvironment = {
  ...Bun.env,
  SWIFT_MODULECACHE_PATH: Bun.env.SWIFT_MODULECACHE_PATH ?? DEFAULT_SWIFT_MODULE_CACHE,
  CLANG_MODULE_CACHE_PATH: Bun.env.CLANG_MODULE_CACHE_PATH ?? DEFAULT_CLANG_MODULE_CACHE,
};

export async function runCommand(command: string[]): Promise<void> {
  const child = Bun.spawn(command, {
    cwd: ROOT_DIR,
    env: commandEnvironment,
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
  const code = await child.exited;
  if (code !== 0) {
    throw new Error("命令失败 (exit " + code + "): " + command.join(" "));
  }
}

export async function captureCommand(command: string[]): Promise<string> {
  const child = Bun.spawn(command, {
    cwd: ROOT_DIR,
    env: commandEnvironment,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [code, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  if (code !== 0) {
    throw new Error(
      "命令失败 (exit " + code + "): " + command.join(" ") + "\n" + stderr.trim(),
    );
  }
  return stdout.trim();
}

async function runCommandCapture(command: string[]): Promise<{
  code: number;
  stdout: string;
  stderr: string;
}> {
  const child = Bun.spawn(command, {
    cwd: ROOT_DIR,
    env: commandEnvironment,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [code, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  return { code, stdout, stderr };
}

function productDirectory(configuration: BuildConfiguration): string {
  return join(
    ROOT_DIR,
    "build/DerivedData/Build/Products",
    configuration === "debug" ? "Debug" : "Release",
  );
}

function appName(configuration: BuildConfiguration): string {
  return configuration === "debug" ? "QLaunch Dev.app" : "QLaunch.app";
}

function assertNumericBuildNumber(buildNumber: string): void {
  if (!/^[1-9][0-9]*$/.test(buildNumber)) {
    throw new Error("Build 号必须是正整数: " + buildNumber);
  }
}

function resolveIconComposerSource(): string | null {
  for (const candidate of ICON_COMPOSER_CANDIDATES) {
    if (existsSync(candidate) && existsSync(join(candidate, "icon.json"))) {
      return candidate;
    }
  }
  return null;
}

function listFilesRecursive(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === ".DS_Store") continue;
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...listFilesRecursive(full));
    } else if (entry.isFile()) {
      out.push(full);
    }
  }
  return out;
}

/** Content fingerprint of a `.icon` package (or a single PNG). */
function fingerprintPath(path: string): string {
  const hash = createHash("sha256");
  const stat = statSync(path);
  if (stat.isDirectory()) {
    const files = listFilesRecursive(path).sort();
    for (const file of files) {
      hash.update(relative(path, file));
      hash.update("\0");
      hash.update(readFileSync(file));
      hash.update("\0");
    }
  } else {
    hash.update(readFileSync(path));
  }
  return hash.digest("hex");
}

interface IconCacheManifest {
  source: string;
  fingerprint: string;
  iconName: string;
  kind: "icon-composer" | "png";
  normalized: boolean;
}

function readIconCacheManifest(): IconCacheManifest | null {
  if (!existsSync(ICON_CACHE_MANIFEST)) return null;
  try {
    return JSON.parse(readFileSync(ICON_CACHE_MANIFEST, "utf8")) as IconCacheManifest;
  } catch {
    return null;
  }
}

function iconCacheArtifactsExist(iconName: string): boolean {
  return (
    existsSync(join(ICON_CACHE_DIR, "Assets.car")) &&
    existsSync(join(ICON_CACHE_DIR, iconName + ".icns"))
  );
}

function writeIconCacheManifest(manifest: IconCacheManifest): void {
  mkdirSync(ICON_CACHE_DIR, { recursive: true });
  writeFileSync(ICON_CACHE_MANIFEST, JSON.stringify(manifest, null, 2) + "\n", "utf8");
}

function copyCachedIconsToApp(resourcesPath: string, iconName: string): void {
  copyFileSync(join(ICON_CACHE_DIR, "Assets.car"), join(resourcesPath, "Assets.car"));
  copyFileSync(
    join(ICON_CACHE_DIR, iconName + ".icns"),
    join(resourcesPath, iconName + ".icns"),
  );
  const cachedPng = join(ICON_CACHE_DIR, "QLaunchpadAppIcon.png");
  if (existsSync(cachedPng)) {
    copyFileSync(cachedPng, ICON_PNG_SOURCE);
  }
}

/**
 * Some Icon Composer exports (refractivity / specular-location feature flags,
 * macOS-only `squares` arrays) make current `actool` crash or emit empty cars.
 * Normalize to a schema that still keeps shadow + translucency + layer images.
 */
function normalizeIconComposerJSON(raw: unknown): { json: unknown; changed: boolean } {
  if (!raw || typeof raw !== "object") {
    return { json: raw, changed: false };
  }
  const data = structuredClone(raw) as Record<string, unknown>;
  let changed = false;

  const platforms = data["supported-platforms"];
  if (
    !platforms ||
    typeof platforms !== "object" ||
    (platforms as Record<string, unknown>)["squares"] !== "shared"
  ) {
    data["supported-platforms"] = { squares: "shared" };
    changed = true;
  }

  if ("features" in data) {
    delete data["features"];
    changed = true;
  }

  const groups = data["groups"];
  if (Array.isArray(groups)) {
    for (const group of groups) {
      if (!group || typeof group !== "object") continue;
      const g = group as Record<string, unknown>;
      for (const key of [
        "refractivity",
        "specular",
        "lighting",
        "blend-mode",
        "blur-material",
      ]) {
        if (key in g) {
          delete g[key];
          changed = true;
        }
      }
    }
  }

  return { json: data, changed };
}

async function actoolCompileIcon(
  iconPackage: string,
  outputDir: string,
  appIconName: string,
): Promise<boolean> {
  mkdirSync(outputDir, { recursive: true });
  const partialPlist = join(outputDir, "assetcatalog_generated_info.plist");
  const result = await runCommandCapture([
    "xcrun",
    "actool",
    iconPackage,
    "--compile",
    outputDir,
    "--output-format",
    "human-readable-text",
    "--notices",
    "--warnings",
    "--errors",
    "--output-partial-info-plist",
    partialPlist,
    "--app-icon",
    appIconName,
    "--include-all-app-icons",
    "--enable-on-demand-resources",
    "NO",
    "--target-device",
    "mac",
    "--minimum-deployment-target",
    "14.0",
    "--platform",
    "macosx",
  ]);

  const carPath = join(outputDir, "Assets.car");
  const icnsPath = join(outputDir, appIconName + ".icns");
  const ok = result.code === 0 && existsSync(carPath) && existsSync(icnsPath);
  if (!ok) {
    const detail = (result.stderr || result.stdout || "").trim();
    if (detail) {
      console.warn("  actool 输出:\n" + detail.split("\n").slice(0, 12).join("\n"));
    }
  }
  return ok;
}

/**
 * Compile Icon Composer `.icon` → `Assets.car` (Liquid Glass on macOS 26+)
 * + `{name}.icns` (older macOS / Finder fallback).
 * Results are stored under `build/icon-cache` and reused until the source changes.
 */
async function compileIconComposer(
  sourceIcon: string,
  resourcesPath: string,
): Promise<{ iconName: string; usedNormalization: boolean; cacheHit: boolean }> {
  const fingerprint = fingerprintPath(sourceIcon);
  const cached = readIconCacheManifest();
  if (
    !FORCE_ICON_REBUILD &&
    cached &&
    cached.kind === "icon-composer" &&
    cached.source === sourceIcon &&
    cached.fingerprint === fingerprint &&
    iconCacheArtifactsExist(cached.iconName)
  ) {
    console.log("▸ 图标缓存命中，跳过 actool: " + sourceIcon);
    copyCachedIconsToApp(resourcesPath, cached.iconName);
    return {
      iconName: cached.iconName,
      usedNormalization: cached.normalized,
      cacheHit: true,
    };
  }

  const workRoot = join(ROOT_DIR, "build/icon-compile");
  rmSync(workRoot, { recursive: true, force: true });
  mkdirSync(workRoot, { recursive: true });
  mkdirSync(ICON_CACHE_DIR, { recursive: true });

  const stagedIcon = join(workRoot, BUNDLE_ICON_NAME + ".icon");
  cpSync(sourceIcon, stagedIcon, { recursive: true });

  const tryCompile = async (label: string): Promise<boolean> => {
    const outDir = join(workRoot, "out-" + label);
    rmSync(outDir, { recursive: true, force: true });
    mkdirSync(outDir, { recursive: true });
    console.log("  actool (" + label + ")…");
    const ok = await actoolCompileIcon(stagedIcon, outDir, BUNDLE_ICON_NAME);
    if (!ok) return false;

    const car = join(outDir, "Assets.car");
    const icns = join(outDir, BUNDLE_ICON_NAME + ".icns");
    copyFileSync(car, join(resourcesPath, "Assets.car"));
    copyFileSync(icns, join(resourcesPath, BUNDLE_ICON_NAME + ".icns"));
    // Persist cache for subsequent dev builds.
    copyFileSync(car, join(ICON_CACHE_DIR, "Assets.car"));
    copyFileSync(icns, join(ICON_CACHE_DIR, BUNDLE_ICON_NAME + ".icns"));

    // Refresh flat PNG for About / SPM resource bundle consumers.
    await exportPNGFromICNS(icns, ICON_PNG_SOURCE);
    copyFileSync(ICON_PNG_SOURCE, join(ICON_CACHE_DIR, "QLaunchpadAppIcon.png"));
    return true;
  };

  let usedNormalization = false;
  if (await tryCompile("raw")) {
    usedNormalization = false;
  } else {
    // Compatibility pass for actool bugs with newer Icon Composer features.
    const jsonPath = join(stagedIcon, "icon.json");
    const original = JSON.parse(readFileSync(jsonPath, "utf8")) as unknown;
    const { json, changed } = normalizeIconComposerJSON(original);
    if (!changed) {
      throw new Error(
        "无法用 actool 编译 Icon Composer 图标: " + sourceIcon +
          "\n请用 Icon Composer 重新导出，或检查 Xcode Command Line Tools。",
      );
    }
    writeFileSync(jsonPath, JSON.stringify(json, null, 2) + "\n", "utf8");
    console.warn(
      "  ⚠️  已对 icon.json 做兼容规范化（去除 refractivity/features 等 actool 崩溃字段，保留阴影与半透明）",
    );
    if (!(await tryCompile("normalized"))) {
      throw new Error(
        "无法用 actool 编译 Icon Composer 图标: " + sourceIcon +
          "\n请用 Icon Composer 重新导出，或检查 Xcode Command Line Tools。",
      );
    }
    usedNormalization = true;
  }

  writeIconCacheManifest({
    source: sourceIcon,
    fingerprint,
    iconName: BUNDLE_ICON_NAME,
    kind: "icon-composer",
    normalized: usedNormalization,
  });

  return {
    iconName: BUNDLE_ICON_NAME,
    usedNormalization,
    cacheHit: false,
  };
}

async function exportPNGFromICNS(icnsPath: string, pngPath: string): Promise<void> {
  mkdirSync(dirname(pngPath), { recursive: true });
  // iconutil expands all representations; pick the largest PNG.
  const iconset = join(dirname(icnsPath), "export-temp.iconset");
  rmSync(iconset, { recursive: true, force: true });
  try {
    await runCommand(["iconutil", "-c", "iconset", icnsPath, "-o", iconset]);
    const files = readdirSync(iconset)
      .filter((name) => name.endsWith(".png"))
      .map((name) => join(iconset, name));
    if (files.length === 0) {
      throw new Error("iconutil 未从 icns 导出任何 PNG");
    }
    // Prefer 1024 / @2x of 512.
    const preferred =
      files.find((f) => f.includes("512x512@2x")) ||
      files.find((f) => f.includes("256x256@2x")) ||
      files.sort((a, b) => b.length - a.length)[0];
    copyFileSync(preferred, pngPath);
    // Ensure 1024 square for marketing consistency.
    await runCommand([
      "sips",
      "-z",
      "1024",
      "1024",
      pngPath,
      "--out",
      pngPath,
    ]);
  } finally {
    rmSync(iconset, { recursive: true, force: true });
  }
}

/** Legacy flat-PNG → iconset → icns pipeline. */
async function createICNSFromPNG(destination: string): Promise<void> {
  if (!existsSync(ICON_PNG_SOURCE)) {
    throw new Error("未找到应用图标 PNG: " + ICON_PNG_SOURCE);
  }

  const iconset = join(dirname(destination), "QLaunch.iconset");
  rmSync(iconset, { recursive: true, force: true });
  mkdirSync(iconset, { recursive: true });

  for (const pointSize of [16, 32, 128, 256, 512]) {
    await runCommand([
      "sips",
      "-z",
      String(pointSize),
      String(pointSize),
      ICON_PNG_SOURCE,
      "--out",
      join(iconset, "icon_" + pointSize + "x" + pointSize + ".png"),
    ]);
    await runCommand([
      "sips",
      "-z",
      String(pointSize * 2),
      String(pointSize * 2),
      ICON_PNG_SOURCE,
      "--out",
      join(iconset, "icon_" + pointSize + "x" + pointSize + "@2x.png"),
    ]);
  }

  mkdirSync(dirname(destination), { recursive: true });
  await runCommand(["iconutil", "-c", "icns", iconset, "-o", destination]);
  rmSync(iconset, { recursive: true, force: true });
}

async function installAppIcon(resourcesPath: string): Promise<{
  iconName: string;
  source: "icon-composer" | "png";
  normalized: boolean;
  cacheHit: boolean;
}> {
  const composer = resolveIconComposerSource();
  if (composer) {
    if (FORCE_ICON_REBUILD) {
      console.log("▸ 强制重编 Icon Composer 图标 (QLAUNCHPAD_FORCE_ICON=1)");
    }
    const result = await compileIconComposer(composer, resourcesPath);
    if (!result.cacheHit) {
      console.log("▸ 已编译 Icon Composer 图标: " + composer);
    }
    return {
      iconName: result.iconName,
      source: "icon-composer",
      normalized: result.usedNormalization,
      cacheHit: result.cacheHit,
    };
  }

  // PNG fallback — also cache by content hash.
  const fingerprint = fingerprintPath(ICON_PNG_SOURCE);
  const cached = readIconCacheManifest();
  const icnsName = BUNDLE_ICON_NAME + ".icns";
  if (
    !FORCE_ICON_REBUILD &&
    cached &&
    cached.kind === "png" &&
    cached.fingerprint === fingerprint &&
    existsSync(join(ICON_CACHE_DIR, icnsName))
  ) {
    console.log("▸ 图标缓存命中 (PNG)，跳过 iconutil");
    copyFileSync(join(ICON_CACHE_DIR, icnsName), join(resourcesPath, icnsName));
    return {
      iconName: BUNDLE_ICON_NAME,
      source: "png",
      normalized: false,
      cacheHit: true,
    };
  }

  console.log("▸ 未找到 .icon，回退 PNG → icns: " + ICON_PNG_SOURCE);
  mkdirSync(ICON_CACHE_DIR, { recursive: true });
  await createICNSFromPNG(join(resourcesPath, icnsName));
  copyFileSync(join(resourcesPath, icnsName), join(ICON_CACHE_DIR, icnsName));
  writeIconCacheManifest({
    source: ICON_PNG_SOURCE,
    fingerprint,
    iconName: BUNDLE_ICON_NAME,
    kind: "png",
    normalized: false,
  });
  return {
    iconName: BUNDLE_ICON_NAME,
    source: "png",
    normalized: false,
    cacheHit: false,
  };
}

function makeInfoPlist(
  productName: string,
  bundleIdentifier: string,
  version: string,
  buildNumber: string,
  iconName: string,
): string {
  return [
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
    "<plist version=\"1.0\">",
    "<dict>",
    "  <key>CFBundleDevelopmentRegion</key>",
    "  <string>zh_CN</string>",
    "  <key>CFBundleDisplayName</key>",
    "  <string>" + productName + "</string>",
    "  <key>CFBundleExecutable</key>",
    "  <string>" + TARGET_NAME + "</string>",
    "  <key>CFBundleIconFile</key>",
    "  <string>" + iconName + "</string>",
    "  <key>CFBundleIconName</key>",
    "  <string>" + iconName + "</string>",
    "  <key>CFBundleIdentifier</key>",
    "  <string>" + bundleIdentifier + "</string>",
    "  <key>CFBundleInfoDictionaryVersion</key>",
    "  <string>6.0</string>",
    "  <key>CFBundleName</key>",
    "  <string>" + productName + "</string>",
    "  <key>CFBundlePackageType</key>",
    "  <string>APPL</string>",
    "  <key>CFBundleShortVersionString</key>",
    "  <string>" + version + "</string>",
    "  <key>CFBundleVersion</key>",
    "  <string>" + buildNumber + "</string>",
    "  <key>LSMinimumSystemVersion</key>",
    "  <string>14.0</string>",
    "  <key>LSUIElement</key>",
    "  <true/>",
    "  <key>NSHighResolutionCapable</key>",
    "  <true/>",
    "  <key>NSPrincipalClass</key>",
    "  <string>NSApplication</string>",
    "</dict>",
    "</plist>",
    "",
  ].join("\n");
}

/** Debugger / Instruments attach requires this for signed Debug apps. */
function makeDebugEntitlements(): string {
  return [
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
    "<plist version=\"1.0\">",
    "<dict>",
    "  <key>com.apple.security.get-task-allow</key>",
    "  <true/>",
    "</dict>",
    "</plist>",
    "",
  ].join("\n");
}

async function signApp(
  appPath: string,
  identity: string,
  options: { allowDebugger?: boolean } = {},
): Promise<void> {
  const args = ["codesign", "--force", "--deep"];
  if (identity !== "-") {
    // Hardened runtime for Developer ID / notarization.
    args.push("--options", "runtime", "--timestamp");
  }

  let entitlementsPath: string | null = null;
  if (options.allowDebugger) {
    // get-task-allow is Debug-only; never ship it on Release / notarized builds.
    entitlementsPath = join(ROOT_DIR, "build/debug-entitlements.plist");
    mkdirSync(dirname(entitlementsPath), { recursive: true });
    writeFileSync(entitlementsPath, makeDebugEntitlements(), "utf8");
    args.push("--entitlements", entitlementsPath);
  }

  args.push("--sign", identity, appPath);
  await runCommand(args);
}

export async function buildApp(options: AppBuildOptions): Promise<AppBuildResult> {
  assertNumericBuildNumber(options.buildNumber);

  const configuration = options.configuration;
  const productName = options.productName ?? (configuration === "debug" ? "QLaunch Dev" : "QLaunch");
  const bundleIdentifier = options.bundleIdentifier ?? (
    configuration === "debug" ? "com.qzrzz.qlaunchpad.dev" : "com.qzrzz.qlaunchpad"
  );
  const scratchPath = join(ROOT_DIR, "build/SwiftPM");

  console.log("▸ 编译 " + (configuration === "debug" ? "Debug" : "Release") + " Swift Package…");
  await runCommand([
    "swift", "build", "-c", configuration, "--scratch-path", scratchPath,
  ]);
  const binPath = await captureCommand([
    "swift", "build", "-c", configuration, "--scratch-path", scratchPath,
    "--show-bin-path",
  ]);

  const executableSource = join(binPath, TARGET_NAME);
  const resourceBundleSource = join(binPath, RESOURCE_BUNDLE_NAME);
  if (!existsSync(executableSource)) {
    throw new Error("未找到 Swift 可执行文件: " + executableSource);
  }
  if (!existsSync(resourceBundleSource)) {
    throw new Error("未找到 Swift 资源包: " + resourceBundleSource);
  }

  const appPath = join(productDirectory(configuration), appName(configuration));
  const contentsPath = join(appPath, "Contents");
  const macOSPath = join(contentsPath, "MacOS");
  const resourcesPath = join(contentsPath, "Resources");
  rmSync(appPath, { recursive: true, force: true });
  mkdirSync(macOSPath, { recursive: true });
  mkdirSync(resourcesPath, { recursive: true });

  const executablePath = join(macOSPath, TARGET_NAME);
  copyFileSync(executableSource, executablePath);
  chmodSync(executablePath, 0o755);

  // Keep SwiftPM resources in the standard signed app bundle location. The
  // app icon loader also supports direct `swift run` launches separately.
  cpSync(resourceBundleSource, join(resourcesPath, basename(resourceBundleSource)), { recursive: true });

  const iconInstall = await installAppIcon(resourcesPath);
  // After Icon Composer compile, PNG in Resources/ may have been refreshed —
  // re-copy SPM resource bundle's app icon if present so packaged app matches.
  const refreshedPng = ICON_PNG_SOURCE;
  const bundledPng = join(
    resourcesPath,
    basename(resourceBundleSource),
    "QLaunchpadAppIcon.png",
  );
  if (existsSync(refreshedPng) && existsSync(dirname(bundledPng))) {
    copyFileSync(refreshedPng, bundledPng);
  }

  writeFileSync(
    join(contentsPath, "Info.plist"),
    makeInfoPlist(
      productName,
      bundleIdentifier,
      options.version,
      options.buildNumber,
      iconInstall.iconName,
    ),
    "utf8",
  );
  console.log(
    "✓ 应用图标: " +
      (iconInstall.source === "icon-composer" ? "Icon Composer (.icon)" : "PNG") +
      (iconInstall.cacheHit ? " [缓存]" : "") +
      (iconInstall.normalized ? " [已兼容规范化]" : ""),
  );

  if (options.signIdentity) {
    const allowDebugger = configuration === "debug";
    console.log(
      "▸ 签署 " + appName(configuration) + " (" + options.signIdentity + ")" +
        (allowDebugger ? " [get-task-allow]" : "") + "…",
    );
    await signApp(appPath, options.signIdentity, { allowDebugger });
  }

  return {
    appPath,
    executablePath,
    configuration,
    version: options.version,
    buildNumber: options.buildNumber,
  };
}
