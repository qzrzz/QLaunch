import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";
import { normalizeSparkleArchiveUrls, verifySparkleArchive } from "./sparkle-artifacts";
import { validateSparkleArtifacts } from "./qrls-publish";

test("同一营销版本的不同 build 保留各自地址，避免覆盖历史签名对应的包", () => {
  const item = (build: string, url: string) => `<item><sparkle:version>${build}</sparkle:version><sparkle:shortVersionString>1.0.25</sparkle:shortVersionString><enclosure url="${url}" /></item>`;
  const previous = item("36", "https://example.com/old36.zip") + item("42", "https://example.com/old42.zip");
  const generated = item("43", "https://example.com/new.zip") + item("42", "https://example.com/wrong.zip") + item("36", "https://example.com/wrong.zip");
  const result = normalizeSparkleArchiveUrls(generated, previous, "43", "https://example.com/QLaunch-1.0.25-43.zip");
  expect(result).toContain('url="https://example.com/QLaunch-1.0.25-43.zip"');
  expect(result).toContain('url="https://example.com/old42.zip"');
  expect(result).toContain('url="https://example.com/old36.zip"');
  expect(result).not.toContain("wrong.zip");
});

test("签名检查拒绝旧缓存字节、错误公钥、缺失签名及大小不匹配", () => {
  const dir = mkdtempSync(join(tmpdir(), "qlaunch-signature-"));
  try {
    const path = join(dir, "update.zip");
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    const key = publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("base64");
    const data = Buffer.from("build42");
    const signature = sign(null, data, privateKey).toString("base64");
    writeFileSync(path, data);
    expect(() => verifySparkleArchive(path, signature, data.length, key)).not.toThrow();
    expect(() => verifySparkleArchive(path, signature, data.length + 1, key)).toThrow("大小");
    expect(() => verifySparkleArchive(path, undefined, data.length, key)).toThrow("缺少");
    const wrongKey = generateKeyPairSync("ed25519").publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("base64");
    expect(() => verifySparkleArchive(path, signature, data.length, wrongKey)).toThrow("签名验证失败");
    writeFileSync(path, "build36");
    expect(() => verifySparkleArchive(path, signature, data.length, key)).toThrow("签名验证失败");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("上传前拒绝复用旧下载地址或 appcast 引用缺失的增量包", () => {
  const dir = mkdtempSync(join(tmpdir(), "qlaunch-preflight-"));
  try {
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    const key = publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("base64");
    const data = Buffer.from("build42");
    const signature = sign(null, data, privateKey).toString("base64");
    const zipPath = join(dir, "QLaunch-1.0.25-42.zip");
    const appcastPath = join(dir, "appcast.xml");
    const xml = `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>42</sparkle:version><sparkle:shortVersionString>1.0.25</sparkle:shortVersionString><enclosure url="https://example.com/QLaunch-1.0.25-42.zip" length="${data.length}" sparkle:edSignature="${signature}" /></item></channel></rss>`;
    const files = { zipPath, appcastPath, notesPath: "", dmgPath: "", deltaPaths: [] };
    writeFileSync(zipPath, data);
    writeFileSync(appcastPath, xml);
    expect(() => validateSparkleArtifacts(files, "1.0.25", "42", key)).not.toThrow();
    writeFileSync(appcastPath, xml.replace("QLaunch-1.0.25-42.zip", "QLaunch-1.0.25.zip"));
    expect(() => validateSparkleArtifacts(files, "1.0.25", "42", key)).toThrow("独立文件名");
    writeFileSync(appcastPath, xml.replace("</item>", '<sparkle:deltas><enclosure url="https://example.com/QLaunch42-36.delta" sparkle:deltaFrom="36" length="7" /></sparkle:deltas></item>'));
    expect(() => validateSparkleArtifacts(files, "1.0.25", "42", key)).toThrow("delta 文件缺失");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
