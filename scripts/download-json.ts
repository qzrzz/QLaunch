#!/usr/bin/env bun

/**
 * 官网 download.json：发布后写入 web/download.json 与 docs/download.json。
 * 站点优先读这份清单直链安装包；若文件缺失，可按本地产物 / 已有清单补一份。
 */

import { existsSync, mkdirSync, readFileSync, renameSync, rmSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { readBuildNumber, readPackageVersion } from "./version";

const ROOT_DIR = join(import.meta.dir, "..");
const DEFAULT_GITHUB_REPOSITORY = "qzrzz/QLaunch";
const ARTIFACT_PREFIX = "QLaunch";
const RELEASE_CACHE_MANIFEST_PATH = join(ROOT_DIR, "release/manifest.json");

export const DOWNLOAD_JSON_PATHS = [
  join(ROOT_DIR, "web/download.json"),
  join(ROOT_DIR, "docs/download.json"),
] as const;

export interface DownloadAssetInfo {
  name: string;
  url: string;
  size: number;
  sha256: string;
}

export interface DownloadManifest {
  schemaVersion: 1;
  name: "QLaunch";
  version: string;
  build: string;
  tag: string;
  publishedAt: string;
  htmlUrl: string;
  dmg: DownloadAssetInfo;
  zip: DownloadAssetInfo;
}

export function githubAssetUrl(repository: string, tag: string, name: string): string {
  return "https://github.com/" + repository + "/releases/download/" + tag + "/" + name;
}

export async function createFileSha256(path: string): Promise<string> {
  const hash = new Bun.CryptoHasher("sha256");
  for await (const chunk of Bun.file(path).stream()) {
    hash.update(chunk);
  }
  return hash.digest("hex");
}

export function isDownloadManifest(value: unknown): value is DownloadManifest {
  if (!value || typeof value !== "object") return false;
  const manifest = value as Partial<DownloadManifest>;
  return (
    manifest.schemaVersion === 1 &&
    manifest.name === "QLaunch" &&
    typeof manifest.version === "string" &&
    /^\d+\.\d+\.\d+$/.test(manifest.version) &&
    typeof manifest.build === "string" &&
    /^[1-9][0-9]*$/.test(manifest.build) &&
    typeof manifest.tag === "string" &&
    manifest.tag.length > 0 &&
    typeof manifest.publishedAt === "string" &&
    Number.isFinite(Date.parse(manifest.publishedAt)) &&
    typeof manifest.htmlUrl === "string" &&
    manifest.htmlUrl.length > 0 &&
    isDownloadAssetInfo(manifest.dmg) &&
    isDownloadAssetInfo(manifest.zip)
  );
}

function isDownloadAssetInfo(value: unknown): value is DownloadAssetInfo {
  if (!value || typeof value !== "object") return false;
  const asset = value as Partial<DownloadAssetInfo>;
  return (
    typeof asset.name === "string" &&
    asset.name.length > 0 &&
    typeof asset.url === "string" &&
    asset.url.length > 0 &&
    typeof asset.size === "number" &&
    Number.isSafeInteger(asset.size) &&
    asset.size > 0 &&
    typeof asset.sha256 === "string" &&
    /^[a-f0-9]{64}$/.test(asset.sha256)
  );
}

export async function describeDownloadAsset(
  path: string,
  repository: string,
  tag: string,
): Promise<DownloadAssetInfo> {
  if (!existsSync(path) || Bun.file(path).size === 0) {
    throw new Error("无法写入官网下载信息：安装包不存在 " + path);
  }
  const name = basename(path);
  return {
    name,
    url: githubAssetUrl(repository, tag, name),
    size: Bun.file(path).size,
    sha256: await createFileSha256(path),
  };
}

export async function buildDownloadManifest(options: {
  version: string;
  build: string;
  repository: string;
  dmgPath: string;
  zipPath: string;
  publishedAt?: string;
}): Promise<DownloadManifest> {
  const { version, build, repository, dmgPath, zipPath } = options;
  const tag = "v" + version;
  return {
    schemaVersion: 1,
    name: "QLaunch",
    version,
    build,
    tag,
    publishedAt: options.publishedAt ?? new Date().toISOString(),
    htmlUrl: "https://github.com/" + repository + "/releases/tag/" + tag,
    dmg: await describeDownloadAsset(dmgPath, repository, tag),
    zip: await describeDownloadAsset(zipPath, repository, tag),
  };
}

export async function writeDownloadManifest(options: {
  version: string;
  build: string;
  repository: string;
  dmgPath: string;
  zipPath: string;
  publishedAt?: string;
}): Promise<DownloadManifest> {
  const manifest = await buildDownloadManifest(options);
  await writeDownloadManifestFiles(manifest);
  return manifest;
}

export async function writeDownloadManifestFiles(manifest: DownloadManifest): Promise<string[]> {
  if (!isDownloadManifest(manifest)) {
    throw new Error("官网 download.json 内容无效");
  }
  const body = JSON.stringify(manifest, null, 2) + "\n";
  const written: string[] = [];
  for (const path of DOWNLOAD_JSON_PATHS) {
    mkdirSync(dirname(path), { recursive: true });
    const temporaryPath = path + "." + process.pid + ".tmp";
    try {
      await Bun.write(temporaryPath, body);
      renameSync(temporaryPath, path);
    } finally {
      rmSync(temporaryPath, { force: true });
    }
    written.push(path);
    console.log("▸ 已写入官网下载信息: " + path);
  }
  return written;
}

export function readExistingDownloadManifest(): DownloadManifest | null {
  for (const path of DOWNLOAD_JSON_PATHS) {
    const manifest = readDownloadManifestFile(path);
    if (manifest) return manifest;
  }
  return null;
}

function readDownloadManifestFile(path: string): DownloadManifest | null {
  if (!existsSync(path)) return null;
  try {
    const value = JSON.parse(readFileSync(path, "utf8")) as unknown;
    return isDownloadManifest(value) ? value : null;
  } catch {
    return null;
  }
}

function resolveLocalArtifactPaths(version: string): { dmgPath?: string; zipPath?: string } {
  const dmgPath = join(ROOT_DIR, "build", ARTIFACT_PREFIX + "-" + version + ".dmg");
  const zipCandidates = [
    join(ROOT_DIR, "build/updates", ARTIFACT_PREFIX + "-" + version + ".zip"),
    join(ROOT_DIR, "release/archives", ARTIFACT_PREFIX + "-" + version + ".zip"),
  ];
  return {
    dmgPath: existsSync(dmgPath) && Bun.file(dmgPath).size > 0 ? dmgPath : undefined,
    zipPath: zipCandidates.find((path) => existsSync(path) && Bun.file(path).size > 0),
  };
}

function readCachedPublishedAt(version: string): string | undefined {
  if (!existsSync(RELEASE_CACHE_MANIFEST_PATH)) return undefined;
  try {
    const value = JSON.parse(readFileSync(RELEASE_CACHE_MANIFEST_PATH, "utf8")) as {
      entries?: Array<{ version?: unknown; publishedAt?: unknown }>;
    };
    const entry = value.entries?.find((item) => item.version === version);
    return typeof entry?.publishedAt === "string" && Number.isFinite(Date.parse(entry.publishedAt))
      ? entry.publishedAt
      : undefined;
  } catch {
    return undefined;
  }
}

/** 两边都缺有效清单时，按 package.json + 本地 DMG/ZIP 生成一份。 */
export async function generateDownloadManifestFromLocalArtifacts(
  repository = DEFAULT_GITHUB_REPOSITORY,
): Promise<DownloadManifest> {
  const version = readPackageVersion();
  const build = readBuildNumber();
  const { dmgPath, zipPath } = resolveLocalArtifactPaths(version);
  if (!dmgPath || !zipPath) {
    throw new Error(
      "没有 download.json，且本地缺少 " + ARTIFACT_PREFIX + "-" + version +
        " 的 DMG/ZIP，无法根据现有信息生成",
    );
  }
  return buildDownloadManifest({
    version,
    build,
    repository,
    dmgPath,
    zipPath,
    publishedAt: readCachedPublishedAt(version),
  });
}

/** 已有有效清单则同步到两个输出位置；否则根据本地产物生成。 */
export async function ensureDownloadManifest(
  repository = DEFAULT_GITHUB_REPOSITORY,
): Promise<DownloadManifest> {
  const existing = readExistingDownloadManifest();
  const manifest = existing ?? (await generateDownloadManifestFromLocalArtifacts(repository));
  const missingOrStale = DOWNLOAD_JSON_PATHS.some((path) => {
    const current = readDownloadManifestFile(path);
    return !current || JSON.stringify(current) !== JSON.stringify(manifest);
  });
  if (missingOrStale) {
    await writeDownloadManifestFiles(manifest);
  }
  return manifest;
}

if (import.meta.main) {
  const manifest = await ensureDownloadManifest();
  console.log(
    "✓ download.json " + manifest.tag + " (build " + manifest.build + ")",
  );
}
