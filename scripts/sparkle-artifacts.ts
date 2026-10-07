import { createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";

/** 下载地址包含 build，避免同一营销版本重发时命中旧的 immutable 缓存。 */
export function sparkleZipName(version: string, build: string): string {
  return `QLaunch-${version}-${build}.zip`;
}

/** 历史地址按 build 保存；同一个营销版本可以有多个构建。 */
export function normalizeSparkleArchiveUrls(
  xml: string,
  previousXml: string,
  build: string,
  archiveUrl: string,
): string {
  const previousUrls = new Map<string, string>();
  const buildOf = (item: string) => item.match(/<sparkle:version>([^<]+)<\/sparkle:version>/)?.[1];
  for (const match of previousXml.matchAll(/<item>[\s\S]*?<\/item>/g)) {
    const previousBuild = buildOf(match[0]);
    const url = match[0].match(/<enclosure\s+url="([^"]+)"/)?.[1];
    if (previousBuild && url) previousUrls.set(previousBuild, url);
  }
  return xml.replace(/<item>[\s\S]*?<\/item>/g, (item) => {
    const itemBuild = buildOf(item);
    const url = itemBuild === build ? archiveUrl : previousUrls.get(itemBuild ?? "");
    return url ? item.replace(/(<enclosure\s+url=")[^"]+(\")/, (_, before, after) => before + url + after) : item;
  });
}

/** 发布前用 App 内置公钥验证实际字节，防止错误签名或签名后改包。 */
export function verifySparkleArchive(
  path: string,
  signature: string | undefined,
  length: number,
  publicKey: string,
): void {
  const data = readFileSync(path);
  if (data.length !== length) throw new Error(`Sparkle 文件大小与 appcast 不符: ${path}`);
  if (!signature) throw new Error(`Sparkle 文件缺少 EdDSA 签名: ${path}`);
  const key = createPublicKey({
    key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(publicKey, "base64")]),
    format: "der",
    type: "spki",
  });
  if (!verify(null, data, key, Buffer.from(signature, "base64"))) {
    throw new Error(`Sparkle 文件签名验证失败: ${path}`);
  }
}
