#!/usr/bin/env bun

/**
 * Locate a packaged QLaunchpad binary and spawn a *new* CLI process.
 * Never `swift run`, never `open -a`, never send argv to a live GUI.
 */

import { existsSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..");

const DEV_EXECUTABLE_SUFFIX = "/QLaunch Dev.app/Contents/MacOS/QLaunchpad";
const RELEASE_EXECUTABLE_SUFFIX = "/QLaunch.app/Contents/MacOS/QLaunchpad";

const DEBUG_APP = join("build/DerivedData/Build/Products/Debug", "QLaunch Dev.app");
const RELEASE_APP = join("build/DerivedData/Build/Products/Release", "QLaunch.app");
const APPLICATIONS_APP = "/Applications/QLaunch.app";

const DEBUG_EXECUTABLE = join(ROOT, DEBUG_APP, "Contents/MacOS/QLaunchpad");
const RELEASE_EXECUTABLE = join(ROOT, RELEASE_APP, "Contents/MacOS/QLaunchpad");
const APPLICATIONS_EXECUTABLE = join(APPLICATIONS_APP, "Contents/MacOS/QLaunchpad");

const CLI_COMMANDS = new Set(["export", "import", "validate", "help", "-h", "--help"]);

function extractExecutable(line: string, marker: string): string | null {
  const index = line.indexOf(marker);
  if (index === -1) return null;
  if (/\bpgrep\b/.test(line)) return null;
  let start = index;
  while (start > 0 && line[start - 1] !== " ") {
    start -= 1;
  }
  return line.slice(start, index + marker.length);
}

function findRunning(marker: string): string | null {
  const result = Bun.spawnSync(["pgrep", "-lf", marker], {
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) return null;
  const text = new TextDecoder().decode(result.stdout);
  for (const line of text.split("\n")) {
    const path = extractExecutable(line, marker);
    if (path && existsSync(path)) return path;
  }
  return null;
}

function resolvePackagedBinary():
  | { ok: true; path: string }
  | { ok: false; runningDev: string | null; runningRelease: string | null } {
  const runningDev = findRunning(DEV_EXECUTABLE_SUFFIX);
  if (runningDev) return { ok: true, path: runningDev };

  const runningRelease = findRunning(RELEASE_EXECUTABLE_SUFFIX);
  if (runningRelease) return { ok: true, path: runningRelease };

  if (existsSync(DEBUG_EXECUTABLE)) return { ok: true, path: DEBUG_EXECUTABLE };
  if (existsSync(RELEASE_EXECUTABLE)) return { ok: true, path: RELEASE_EXECUTABLE };
  if (existsSync(APPLICATIONS_EXECUTABLE)) return { ok: true, path: APPLICATIONS_EXECUTABLE };

  return { ok: false, runningDev, runningRelease };
}

function printMissingBinary(
  runningDev: string | null,
  runningRelease: string | null,
): void {
  console.error("未找到 QLaunch Dev.app / QLaunch.app。");
  console.error("已探测:");
  console.error(
    "  (running) " + (runningDev ?? "…/QLaunch Dev.app/Contents/MacOS/QLaunchpad"),
  );
  console.error(
    "  (running) " + (runningRelease ?? "…/QLaunch.app/Contents/MacOS/QLaunchpad"),
  );
  console.error("  " + DEBUG_APP);
  console.error("  " + RELEASE_APP);
  console.error("  " + APPLICATIONS_APP);
  console.error("请先 bun run dev");
}

function printUsage(): void {
  console.log(`Usage:
  bun run layout:export -- [--out <path>|-] [--pretty|--compact] [--no-catalog] [--no-paths]
  bun run layout:import -- [--in <path>|-] [--merge|--replace] [--strict] [--dry-run]
  bun run layout:validate -- [--in <path>|-]

Spawns a new packaged QLaunchpad process (QLaunch Dev.app / QLaunch.app).
Does not call swift run, open -a, or send arguments to a running GUI.
`);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const command = args.find((arg) => CLI_COMMANDS.has(arg));
  if (command == null) {
    console.error("error: missing export|import|validate command");
    printUsage();
    process.exit(1);
  }
  if (
    (command === "help" || command === "-h" || command === "--help") &&
    args.every((arg) => CLI_COMMANDS.has(arg) || arg === "--cli")
  ) {
    printUsage();
    process.exit(0);
  }

  const resolved = resolvePackagedBinary();
  if (!resolved.ok) {
    printMissingBinary(resolved.runningDev, resolved.runningRelease);
    process.exit(1);
  }

  const child = Bun.spawn([resolved.path, ...args], {
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
  const code = await child.exited;
  process.exit(code ?? 1);
}

main().catch((error) => {
  console.error("✗ " + (error instanceof Error ? error.message : error));
  process.exit(1);
});
