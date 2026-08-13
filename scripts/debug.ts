#!/usr/bin/env bun

/**
 * Debug 构建并分析。
 *
 * 默认：xctrace Time Profiler（launch，Ctrl-C 结束，再打开 .trace）。
 * `--gui`：打开匹配的 Instruments，需自己选 Time Profiler。
 * `--heap`：MallocStackLogging 启动，用 heap / leaks 看内存。
 *
 * macOS 27 + Xcode 27 beta：Allocations / Leaks 会因 liboainject
 * 找不到 `_pthread_self` 而 Failed to attach。这是 Instruments 的
 * ObjectAlloc 注入 bug，不是 App 签名问题。请用 Time Profiler 或 --heap。
 *
 *   bun run debug
 *   bun run debug -- --gui
 *   bun run debug -- --heap
 */

import { existsSync, readdirSync } from "node:fs";
import { buildApp, captureCommand, runCommand } from "./build-app";
import { readBuildNumber, readPackageVersion } from "./version";

interface XcodeInstall {
  appPath: string;
  developerDir: string;
  instrumentsPath: string;
  version: string;
}

function parseVersion(version: string): number[] {
  return version.split(".").map((part) => Number.parseInt(part, 10) || 0);
}

function compareVersion(left: string, right: string): number {
  const a = parseVersion(left);
  const b = parseVersion(right);
  const length = Math.max(a.length, b.length);
  for (let index = 0; index < length; index += 1) {
    const delta = (a[index] ?? 0) - (b[index] ?? 0);
    if (delta !== 0) return delta;
  }
  return 0;
}

async function readXcodeVersion(appPath: string): Promise<string | null> {
  try {
    return await captureCommand([
      "defaults",
      "read",
      appPath + "/Contents/Info",
      "CFBundleShortVersionString",
    ]);
  } catch {
    return null;
  }
}

function appPathFromDeveloperDir(developerDir: string): string {
  return developerDir.replace(/\/Contents\/Developer\/?$/, "");
}

async function resolveXcode(): Promise<XcodeInstall> {
  const envDir = process.env.DEVELOPER_DIR;
  if (envDir && existsSync(envDir)) {
    const appPath = appPathFromDeveloperDir(envDir);
    return {
      appPath,
      developerDir: envDir,
      instrumentsPath: appPath + "/Contents/Applications/Instruments.app",
      version: (await readXcodeVersion(appPath)) ?? "0",
    };
  }

  const candidates = new Set<string>([
    "/Applications/Xcode-beta.app",
    "/Applications/Xcode.app",
  ]);
  try {
    for (const name of readdirSync("/Applications")) {
      if (/^Xcode.*\.app$/i.test(name)) {
        candidates.add("/Applications/" + name);
      }
    }
  } catch {
    // /Applications unreadable — fall through to the known names.
  }

  const installs: XcodeInstall[] = [];
  for (const appPath of candidates) {
    const developerDir = appPath + "/Contents/Developer";
    const instrumentsPath = appPath + "/Contents/Applications/Instruments.app";
    if (!existsSync(developerDir) || !existsSync(instrumentsPath)) continue;
    const version = await readXcodeVersion(appPath);
    if (!version) continue;
    installs.push({ appPath, developerDir, instrumentsPath, version });
  }

  installs.sort((left, right) => compareVersion(right.version, left.version));
  if (installs[0] == null) {
    throw new Error("未找到可用的 Xcode / Instruments（Xcode.app 或 Xcode-beta.app）");
  }
  return installs[0];
}

async function developerModeEnabled(): Promise<boolean | null> {
  try {
    const status = await captureCommand(["DevToolsSecurity", "-status"]);
    return !/disabled/i.test(status);
  } catch {
    return null;
  }
}

function printDeveloperModeHelp(): void {
  console.warn("⚠️  Developer Mode 当前为关闭状态。");
  console.warn("   请开启：系统设置 → 隐私与安全性 → 开发者模式");
  console.warn("   或执行：sudo DevToolsSecurity -enable\n");
}

function printAllocationsBugHelp(): void {
  console.warn("⚠️  不要用 Allocations / Leaks 模板。");
  console.warn("   macOS 27 上 liboainject 无法解析 libsystem_pthread.dylib 的 _pthread_self，");
  console.warn("   Instruments 会报 Failed to attach / missing bootstrapping symbols。");
  console.warn("   CPU：本脚本默认的 Time Profiler（可用）。");
  console.warn("   内存：bun run debug -- --heap，然后 heap <pid> / leaks <pid>。\n");
}

function hasFlag(...flags: string[]): boolean {
  return flags.some((flag) => process.argv.includes(flag));
}

async function recordTimeProfiler(executablePath: string): Promise<void> {
  console.log("▸ xctrace Time Profiler（launch）。在 App 里复现后按 Ctrl-C 结束录制。");
  console.log("  可执行文件: " + executablePath);
  await runCommand([
    "xcrun",
    "xctrace",
    "record",
    "--template",
    "Time Profiler",
    "--launch",
    "--",
    executablePath,
  ]);
}

async function launchWithHeapLogging(executablePath: string): Promise<void> {
  console.log("▸ 以 MallocStackLogging 启动（不经过 liboainject）…");
  const child = Bun.spawn([executablePath], {
    env: {
      ...process.env,
      MallocStackLogging: "1",
      MallocStackLoggingNoCompact: "1",
    },
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
  const pid = child.pid;
  console.log("  pid: " + pid);
  console.log("  另开终端：");
  console.log("    heap " + pid);
  console.log("    leaks " + pid);
  console.log("    malloc_history " + pid + " -all_by_size");
  const code = await child.exited;
  if (code !== 0) {
    throw new Error("进程退出码 " + code);
  }
}

async function main(): Promise<void> {
  const xcode = await resolveXcode();
  process.env.DEVELOPER_DIR = xcode.developerDir;

  const guiMode = hasFlag("--gui", "-g");
  const heapMode = hasFlag("--heap", "--memory", "-m");
  const recordMode = hasFlag("--record", "-r") || (!guiMode && !heapMode);
  const developerMode = await developerModeEnabled();

  console.log("▸ Xcode " + xcode.version + "  (" + xcode.appPath + ")");
  if (developerMode === false) {
    printDeveloperModeHelp();
    if (recordMode) {
      throw new Error("请先开启 Developer Mode");
    }
  }

  const app = await buildApp({
    configuration: "debug",
    version: readPackageVersion(),
    buildNumber: readBuildNumber(),
    productName: "QLaunch Dev",
    bundleIdentifier: "com.qzrzz.qlaunchpad.dev",
    signIdentity: "-",
  });

  if (!existsSync(app.executablePath)) {
    throw new Error("未找到 Debug 可执行文件: " + app.executablePath);
  }

  if (heapMode) {
    await launchWithHeapLogging(app.executablePath);
    return;
  }

  if (guiMode) {
    printAllocationsBugHelp();
    console.log("▸ 打开 Instruments " + xcode.version + "…");
    console.log("  App: " + app.appPath);
    console.log("  请选 Time Profiler 或 CPU Profiler，再 Choose Target → 本 App → Record。");
    console.log("  不要选 Allocations / Leaks，也不要 attach /Applications/QLaunchpad.app。");
    await runCommand(["open", "-a", xcode.instrumentsPath, app.appPath]);
    return;
  }

  await recordTimeProfiler(app.executablePath);
}

main().catch((error) => {
  console.error("\n✗ " + (error instanceof Error ? error.message : error));
  process.exit(1);
});
