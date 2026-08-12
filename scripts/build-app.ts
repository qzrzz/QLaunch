#!/usr/bin/env bun

import {
  chmodSync,
  cpSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";

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
const ICON_SOURCE = join(ROOT_DIR, "Sources/QLaunchpad/Resources/QLaunchpadAppIcon.png");
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

function productDirectory(configuration: BuildConfiguration): string {
  return join(
    ROOT_DIR,
    "build/DerivedData/Build/Products",
    configuration === "debug" ? "Debug" : "Release",
  );
}

function appName(configuration: BuildConfiguration): string {
  return configuration === "debug" ? "QLaunchpad Dev.app" : "QLaunchpad.app";
}

function assertNumericBuildNumber(buildNumber: string): void {
  if (!/^[1-9][0-9]*$/.test(buildNumber)) {
    throw new Error("Build 号必须是正整数: " + buildNumber);
  }
}

async function createICNS(destination: string): Promise<void> {
  if (!existsSync(ICON_SOURCE)) {
    throw new Error("未找到应用图标: " + ICON_SOURCE);
  }

  const iconset = join(dirname(destination), "QLaunchpad.iconset");
  rmSync(iconset, { recursive: true, force: true });
  mkdirSync(iconset, { recursive: true });

  for (const pointSize of [16, 32, 128, 256, 512]) {
    await runCommand([
      "sips", "-z", String(pointSize), String(pointSize), ICON_SOURCE,
      "--out", join(iconset, "icon_" + pointSize + "x" + pointSize + ".png"),
    ]);
    await runCommand([
      "sips", "-z", String(pointSize * 2), String(pointSize * 2), ICON_SOURCE,
      "--out", join(iconset, "icon_" + pointSize + "x" + pointSize + "@2x.png"),
    ]);
  }

  mkdirSync(dirname(destination), { recursive: true });
  await runCommand(["iconutil", "-c", "icns", iconset, "-o", destination]);
  rmSync(iconset, { recursive: true, force: true });
}

function makeInfoPlist(
  productName: string,
  bundleIdentifier: string,
  version: string,
  buildNumber: string,
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
    "  <string>QLaunchpad.icns</string>",
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

async function signApp(appPath: string, identity: string): Promise<void> {
  const args = ["codesign", "--force", "--deep"];
  if (identity !== "-") {
    args.push("--options", "runtime", "--timestamp");
  }
  args.push("--sign", identity, appPath);
  await runCommand(args);
}

export async function buildApp(options: AppBuildOptions): Promise<AppBuildResult> {
  assertNumericBuildNumber(options.buildNumber);

  const configuration = options.configuration;
  const productName = options.productName ?? (configuration === "debug" ? "QLaunchpad Dev" : "QLaunchpad");
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

  await createICNS(join(resourcesPath, "QLaunchpad.icns"));
  writeFileSync(
    join(contentsPath, "Info.plist"),
    makeInfoPlist(productName, bundleIdentifier, options.version, options.buildNumber),
    "utf8",
  );

  if (options.signIdentity) {
    console.log("▸ 签署 " + appName(configuration) + " (" + options.signIdentity + ")…");
    await signApp(appPath, options.signIdentity);
  }

  return {
    appPath,
    executablePath,
    configuration,
    version: options.version,
    buildNumber: options.buildNumber,
  };
}
