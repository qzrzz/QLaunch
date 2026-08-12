#!/usr/bin/env bun

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const PACKAGE_JSON_PATH = join(import.meta.dir, "..", "package.json");

interface PackageMetadata {
  version?: unknown;
  buildNumber?: unknown;
  [key: string]: unknown;
}

function readPackage(): PackageMetadata {
  if (!existsSync(PACKAGE_JSON_PATH)) {
    throw new Error("未找到 package.json: " + PACKAGE_JSON_PATH);
  }
  return JSON.parse(readFileSync(PACKAGE_JSON_PATH, "utf8")) as PackageMetadata;
}

export function isSemVer(value: string): boolean {
  return /^\d+\.\d+\.\d+$/.test(value);
}

export function readPackageVersion(): string {
  const packageJson = readPackage();
  if (typeof packageJson.version !== "string" || !isSemVer(packageJson.version)) {
    throw new Error("package.json 中未找到有效的 X.Y.Z version");
  }
  return packageJson.version;
}

export function readBuildNumber(): string {
  const packageJson = readPackage();
  const value = Number(packageJson.buildNumber ?? 1);
  if (!Number.isInteger(value) || value < 1) {
    throw new Error("package.json 中的 buildNumber 必须是正整数");
  }
  return String(value);
}

export function syncVersionAndBumpBuildNumber(versionOverride?: string): {
  version: string;
  buildNumber: string;
} {
  const packageJson = readPackage();
  const version = versionOverride ?? readPackageVersion();
  if (!isSemVer(version)) {
    throw new Error("版本号必须是 X.Y.Z: " + version);
  }

  const currentBuild = Number(packageJson.buildNumber ?? 1);
  if (!Number.isInteger(currentBuild) || currentBuild < 1) {
    throw new Error("package.json 中的 buildNumber 必须是正整数");
  }

  const buildNumber = currentBuild + 1;
  packageJson.version = version;
  packageJson.buildNumber = buildNumber;
  writeFileSync(PACKAGE_JSON_PATH, JSON.stringify(packageJson, null, 2) + "\n", "utf8");
  return { version, buildNumber: String(buildNumber) };
}
