#!/usr/bin/env bun

import { rmSync } from "node:fs";
import { join } from "node:path";

const rootDir = join(import.meta.dir, "..");
rmSync(join(rootDir, "build"), { recursive: true, force: true });
rmSync(join(rootDir, ".build"), { recursive: true, force: true });
console.log("✓ 已清理 build/ 与 .build/");
