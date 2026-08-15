/**
 * 用 QRls 把已签名的 QLaunch 安装包发到 R2（主源），并可选同步到 GitHub。
 * Sparkle 签名与 delta 仍由本仓库 generate_appcast 生成，这里只负责上传和改写 enclosure URL。
 */
import { existsSync, readFileSync } from "node:fs";
import { basename } from "node:path";
import {
  parseSparkleAppcast,
  qrls,
  type IFileInput,
  type IQRlsVersionResult,
} from "qrls";

/** R2 公开访问前缀，末尾不含斜杠。 */
export const R2_ONLINE_URL = (
  process.env.R2_ONLINE_URL ?? "https://download.qzrzz.com/qlaunch"
).replace(/\/+$/, "");

/** R2 存储桶名。凭据从环境变量或 ~/.config/qrls/qrls.config.json 读取。 */
export const R2_BUCKET = process.env.R2_BUCKET ?? "qzrzz-download";

/** R2 对象键前缀。 */
export const R2_PATH = process.env.R2_PATH ?? "qlaunch";

/** 默认仍把同一份订阅同步到 GitHub，方便旧版 App 读到新 feed。 */
export const PUBLISH_GITHUB = process.env.PUBLISH_GITHUB !== "0";

/**
 * 拼接 R2 公开下载地址
 * @param fileName 对象文件名
 */
export function r2PublicUrl(fileName: string): string {
  return `${R2_ONLINE_URL}/${fileName}`;
}

/** 建议写入 Info.plist SUFeedURL 的稳定订阅地址。 */
export const SPARKLE_FEED_URL = r2PublicUrl("appcast.xml");

/** 一次发布需要的本地产物路径。 */
export interface IQrlsPublishFiles {
  dmgPath: string;
  zipPath: string;
  notesPath: string;
  appcastPath: string;
  deltaPaths: string[];
}

/** 发布身份与渠道。 */
export interface IQrlsPublishInput extends IQrlsPublishFiles {
  name: string;
  version: string;
  build: string;
  repository: string;
  changelog?: string;
  force?: boolean;
  statePath?: string;
}

/**
 * 从本机 generate_appcast 产物里抽出当前 build 的 EdDSA 签名
 * @param appcastPath 本地 appcast.xml
 * @param build CURRENT_PROJECT_VERSION
 */
export function readSparkleSignatures(
  appcastPath: string,
  build: string,
): {
  zipSignature?: string;
  deltas: Array<{ name: string; edSignature?: string; deltaFromVersion?: string }>;
} {
  if (!existsSync(appcastPath)) {
    return { deltas: [] };
  }
  const items = parseSparkleAppcast(readFileSync(appcastPath, "utf8"));
  const current = items.find((item) => item.buildVersion === build);
  if (!current) {
    return { deltas: [] };
  }
  return {
    zipSignature: current.mainFile.sparkle?.edSignature,
    deltas: (current.deltaFiles ?? []).map((delta) => ({
      name: delta.name,
      edSignature: delta.sparkle?.edSignature,
      deltaFromVersion: delta.deltaFromVersion ?? delta.sparkle?.deltaFromVersion,
    })),
  };
}

/**
 * 把 ZIP / 说明 / delta 编成 QRls 附件列表，并带上 Sparkle 签名
 * @param files 本地产物
 * @param build 当前构建号
 */
export function collectSparkleAttachments(
  files: IQrlsPublishFiles,
  build: string,
): IFileInput[] {
  const signatures = readSparkleSignatures(files.appcastPath, build);
  const attachments: IFileInput[] = [
    {
      data: files.zipPath,
      name: basename(files.zipPath),
      edSignature: signatures.zipSignature,
    },
  ];
  if (existsSync(files.notesPath)) {
    attachments.push({
      data: files.notesPath,
      name: basename(files.notesPath),
    });
  }

  const signatureByName = new Map(
    signatures.deltas.map((delta) => [delta.name, delta]),
  );
  for (const deltaPath of files.deltaPaths) {
    const name = basename(deltaPath);
    const signed = signatureByName.get(name);
    attachments.push({
      data: deltaPath,
      name,
      edSignature: signed?.edSignature,
      deltaFromVersion: signed?.deltaFromVersion,
    });
  }
  return attachments;
}

/**
 * 调用 QRls：主发 R2，可选同步 GitHub
 * @param input 版本与本地产物
 */
export async function publishWithQrls(
  input: IQrlsPublishInput,
): Promise<IQRlsVersionResult> {
  if (!existsSync(input.dmgPath) || !existsSync(input.zipPath)) {
    throw new Error("QRls 发布缺少已公证的 DMG 或 Sparkle ZIP");
  }

  const changelog =
    input.changelog ||
    (existsSync(input.notesPath) ? readFileSync(input.notesPath, "utf8") : "");

  return qrls({
    name: input.name,
    version: input.version,
    buildVersion: input.build,
    changelog,
    variants: {
      "macos-arm": {
        main: {
          data: input.dmgPath,
          name: basename(input.dmgPath),
        },
        files: collectSparkleAttachments(input, input.build),
      },
    },
    sparkle: {
      enabled: true,
      origin: "r2",
      publishFeedTo: PUBLISH_GITHUB ? ["r2", "github"] : ["r2"],
      enclosure: "zip",
      mergeExisting: true,
      existingAppcast: existsSync(input.appcastPath)
        ? readFileSync(input.appcastPath, "utf8")
        : undefined,
      maximumVersions: 10,
      title: `${input.name} Updates`,
      language: "zh-CN",
    },
    historyMax: 0,
    force: input.force === true,
    statePath: input.statePath,
    verbose: true,
    target: {
      r2: {
        onlineUrl: R2_ONLINE_URL,
        bucket: R2_BUCKET,
        path: R2_PATH,
      },
      ...(PUBLISH_GITHUB
        ? {
            github: {
              repo: input.repository,
            },
          }
        : {}),
    },
  });
}
