#!/usr/bin/env bun

/**
 * Locate a packaged QLaunchpad binary and spawn a *new* CLI process.
 * Never `swift run`, never `open -a`, never send argv to a live GUI.
 */

import { existsSync } from "node:fs";
import { join, resolve } from "node:path";

const ROOT = resolve(join(import.meta.dir, ".."));

const DEV_EXECUTABLE_SUFFIX = "/QLaunch Dev.app/Contents/MacOS/QLaunchpad";
const RELEASE_EXECUTABLE_SUFFIX = "/QLaunch.app/Contents/MacOS/QLaunchpad";

const DEBUG_APP = join("build/DerivedData/Build/Products/Debug", "QLaunch Dev.app");
const RELEASE_APP = join("build/DerivedData/Build/Products/Release", "QLaunch.app");
const APPLICATIONS_APP = "/Applications/QLaunch.app";

const DEBUG_EXECUTABLE = join(ROOT, DEBUG_APP, "Contents/MacOS/QLaunchpad");
const RELEASE_EXECUTABLE = join(ROOT, RELEASE_APP, "Contents/MacOS/QLaunchpad");
const APPLICATIONS_EXECUTABLE = join(APPLICATIONS_APP, "Contents/MacOS/QLaunchpad");

const CLI_COMMANDS = new Set(["export", "import", "validate", "help", "-h", "--help"]);

export function extractExecutable(line: string, marker: string): string | null {
  if (/\bpgrep\b/.test(line)) return null;
  const match = line.match(/^\s*\d+\s+(.*)$/);
  if (match == null) return null;
  const command = match[1] ?? "";
  const index = command.indexOf(marker);
  if (index === -1) return null;
  const slash = command.indexOf("/");
  if (slash === -1 || slash > index) return null;
  return command.slice(slash, index + marker.length);
}

function isUnderRoot(path: string): boolean {
  const resolved = resolve(path);
  return resolved === ROOT || resolved.startsWith(ROOT + "/");
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
  if (runningDev && isUnderRoot(runningDev)) return { ok: true, path: runningDev };

  const runningRelease = findRunning(RELEASE_EXECUTABLE_SUFFIX);
  if (runningRelease && isUnderRoot(runningRelease)) return { ok: true, path: runningRelease };

  if (existsSync(DEBUG_EXECUTABLE)) return { ok: true, path: DEBUG_EXECUTABLE };
  if (existsSync(RELEASE_EXECUTABLE)) return { ok: true, path: RELEASE_EXECUTABLE };
  if (existsSync(APPLICATIONS_EXECUTABLE)) return { ok: true, path: APPLICATIONS_EXECUTABLE };

  return { ok: false, runningDev, runningRelease };
}

function normalizeCLIArgv(args: string[]):
  | { ok: true; argv: string[] }
  | { ok: true; helpOnly: true }
  | { ok: false; error: string } {
  const filtered = args.filter((arg) => arg !== "--cli");
  let command: string | null = null;
  const rest: string[] = [];
  for (const arg of filtered) {
    if (command == null && CLI_COMMANDS.has(arg)) {
      command = arg;
      continue;
    }
    rest.push(arg);
  }
  if (command == null) {
    return { ok: false, error: "missing export|import|validate command" };
  }
  if (
    (command === "help" || command === "-h" || command === "--help") &&
    rest.length === 0
  ) {
    return { ok: true, helpOnly: true };
  }
  // Subcommand is argv[0] after --cli so LaunchpadCLI.isInvocation is true.
  return { ok: true, argv: ["--cli", command, ...rest] };
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
  const normalized = normalizeCLIArgv(process.argv.slice(2));
  if (!normalized.ok) {
    console.error("error: " + normalized.error);
    printUsage();
    process.exit(1);
  }
  if ("helpOnly" in normalized) {
    printUsage();
    process.exit(0);
  }

  const resolved = resolvePackagedBinary();
  if (!resolved.ok) {
    printMissingBinary(resolved.runningDev, resolved.runningRelease);
    process.exit(1);
  }

  const child = Bun.spawn([resolved.path, ...normalized.argv], {
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
  const code = await child.exited;
  process.exit(code ?? 1);
}

if (import.meta.main) {
  main().catch((error) => {
    console.error("✗ " + (error instanceof Error ? error.message : error));
    process.exit(1);
  });
}
