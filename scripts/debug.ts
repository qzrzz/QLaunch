#!/usr/bin/env bun

/**
 * Debug 构建并用 Instruments 分析。
 *
 * 默认：编译 Debug .app 后用 `open -a Instruments` 打开（手动选模板 / 附加）。
 * `--record` / `-r`：用 xctrace Time Profiler 直接 launch 录制。
 *
 * 用法：
 *   bun run debug
 *   bun run debug -- --record
 *
 * Attach 失败（Failed to attach to target process）时请检查：
 * 1. 系统已开启 Developer Mode（设置 → 隐私与安全性 → 开发者模式）
 *    或终端执行：sudo DevToolsSecurity -enable
 * 2. 使用本脚本打出的 Debug 包（含 get-task-allow）
 * 3. 优先用 --record 让 Instruments 自己 launch，不要 attach 旧进程
 */

import { existsSync } from "node:fs";
import { buildApp, captureCommand, runCommand } from "./build-app";
import { readBuildNumber, readPackageVersion } from "./version";

async function ensureDeveloperModeHint(): Promise<void> {
  try {
    const status = await captureCommand(["DevToolsSecurity", "-status"]);
    if (/disabled/i.test(status)) {
      console.warn("⚠️  Developer Mode 当前为关闭状态，Instruments/lldb 无法 attach。");
      console.warn("   请开启：系统设置 → 隐私与安全性 → 开发者模式");
      console.warn("   或执行：sudo DevToolsSecurity -enable");
      console.warn("   开启后可能需要重启并再次输入密码确认。\n");
    }
  } catch {
    // Tooling missing — skip the hint.
  }
}

async function main(): Promise<void> {
  process.env.DEVELOPER_DIR ??= "/Applications/Xcode.app/Contents/Developer";

  const recordMode =
    process.argv.includes("--record") || process.argv.includes("-r");

  await ensureDeveloperModeHint();

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

  if (recordMode) {
    console.log("▸ 启动 xctrace Time Profiler（launch 模式，避免 attach 失败）…");
    console.log("  可执行文件: " + app.executablePath);
    await runCommand([
      "xcrun",
      "xctrace",
      "record",
      "--template",
      "Time Profiler",
      "--launch",
      "--",
      app.executablePath,
    ]);
  } else {
    console.log("▸ 打开 Instruments…");
    console.log("  App: " + app.appPath);
    console.log("  提示：在 Instruments 里用 Choose Target → 选择本 App，或用 All Processes 后 launch。");
    console.log("  若出现 Failed to attach：优先 bun run debug -- --record，并确认已开启 Developer Mode。");
    await runCommand(["open", "-a", "Instruments", app.appPath]);
  }
}

main().catch((error) => {
  console.error("\n✗ " + (error instanceof Error ? error.message : error));
  process.exit(1);
});
