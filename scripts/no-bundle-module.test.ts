import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { expect, test } from "bun:test";

const ROOT_DIR = join(import.meta.dir, "..");
const APP_SOURCES = join(ROOT_DIR, "Sources/QLaunchpad");

function listSwiftFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...listSwiftFiles(full));
    } else if (entry.name.endsWith(".swift")) {
      out.push(full);
    }
  }
  return out;
}

/** Drop line and block comments so only real code is scanned. */
function stripSwiftComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
}

test("Sources/QLaunchpad 不得使用 Bundle.module（发布包会 fatalError）", () => {
  const hits: string[] = [];
  for (const file of listSwiftFiles(APP_SOURCES)) {
    if (stripSwiftComments(readFileSync(file, "utf8")).includes("Bundle.module")) {
      hits.push(relative(ROOT_DIR, file));
    }
  }
  expect(hits).toEqual([]);
});
