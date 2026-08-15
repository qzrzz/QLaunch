import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import {
  DOWNLOAD_URL,
  getRootRelativePath,
  type SupportedLang,
} from "./i18n/dict";

export const DOWNLOAD_JSON_NAME = "download.json";

export interface DownloadAsset {
  name: string;
  url: string;
  size: number;
  sha256: string;
}

export interface DownloadManifest {
  schemaVersion: 1;
  name: string;
  version: string;
  build?: string;
  tag: string;
  publishedAt?: string;
  htmlUrl: string;
  dmg: DownloadAsset;
  zip?: DownloadAsset;
}

export interface DownloadLink {
  href: string;
  version?: string;
  filename?: string;
  size?: number;
  isDirect: boolean;
}

const FALLBACK_LINK: DownloadLink = {
  href: DOWNLOAD_URL,
  isDirect: false,
};

export function formatDownloadVersion(version: string): string {
  return version.startsWith("v") ? version : "v" + version;
}

export function formatDownloadSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "";
  const mb = bytes / (1024 * 1024);
  if (mb >= 10) return `${Math.round(mb)} MB`;
  if (mb >= 0.1) return `${mb.toFixed(1)} MB`;
  return `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

const DownloadContext = createContext<DownloadLink>(FALLBACK_LINK);

function isTrustedDmgUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    return (
      parsed.protocol === "https:" &&
      parsed.hostname === "github.com" &&
      parsed.pathname.startsWith("/qzrzz/QLaunch/releases/download/") &&
      parsed.pathname.toLowerCase().endsWith(".dmg")
    );
  } catch {
    return false;
  }
}

function isDownloadAsset(value: unknown): value is DownloadAsset {
  if (!value || typeof value !== "object") return false;
  const asset = value as Partial<DownloadAsset>;
  return (
    typeof asset.name === "string" &&
    asset.name.length > 0 &&
    typeof asset.url === "string" &&
    asset.url.length > 0
  );
}

export function parseDownloadManifest(value: unknown): DownloadManifest | null {
  if (!value || typeof value !== "object") return null;
  const manifest = value as Partial<DownloadManifest>;
  if (typeof manifest.version !== "string" || !manifest.version) return null;
  if (typeof manifest.tag !== "string" || !manifest.tag) return null;
  if (typeof manifest.htmlUrl !== "string" || !manifest.htmlUrl) return null;
  if (!isDownloadAsset(manifest.dmg) || !isTrustedDmgUrl(manifest.dmg.url)) {
    return null;
  }
  return manifest as DownloadManifest;
}

export function getDownloadJsonUrl(lang?: SupportedLang): string {
  return getRootRelativePath(DOWNLOAD_JSON_NAME, lang);
}

export async function loadDownloadManifest(
  lang?: SupportedLang,
): Promise<DownloadManifest | null> {
  try {
    const response = await fetch(getDownloadJsonUrl(lang), { cache: "no-cache" });
    if (!response.ok) return null;
    return parseDownloadManifest(await response.json());
  } catch {
    return null;
  }
}

function manifestToLink(manifest: DownloadManifest): DownloadLink {
  return {
    href: manifest.dmg.url,
    version: formatDownloadVersion(manifest.version),
    filename: manifest.dmg.name,
    size: manifest.dmg.size,
    isDirect: true,
  };
}

export function DownloadProvider({
  lang,
  children,
}: {
  lang: SupportedLang;
  children: ReactNode;
}) {
  const [link, setLink] = useState<DownloadLink>(FALLBACK_LINK);

  useEffect(() => {
    let cancelled = false;
    loadDownloadManifest(lang).then((manifest) => {
      if (cancelled || !manifest) return;
      setLink(manifestToLink(manifest));
    });
    return () => {
      cancelled = true;
    };
  }, [lang]);

  return (
    <DownloadContext.Provider value={link}>{children}</DownloadContext.Provider>
  );
}

export function useDownloadLink(): DownloadLink {
  return useContext(DownloadContext);
}

interface DownloadAnchorProps {
  className?: string;
  children: ReactNode;
}

/** 已发布时直链 DMG；清单不可用时回退到 GitHub Releases。 */
export function DownloadAnchor({ className, children }: DownloadAnchorProps) {
  const { href, filename, isDirect } = useDownloadLink();
  if (isDirect) {
    return (
      <a
        className={className}
        href={href}
        download={filename}
        rel="noopener noreferrer"
      >
        {children}
      </a>
    );
  }
  return (
    <a className={className} href={href} target="_blank" rel="noreferrer">
      {children}
    </a>
  );
}
