/** 官网支持的语言。 */
export type SupportedLang = "en" | "zh-Hans";

/** 语言选择持久化 key */
export const STORAGE_LANG_KEY = "qlaunchpad_lang";

/** 支持的语言列表（用于切换器与构建）。 */
export const SUPPORTED_LANGS: SupportedLang[] = ["en", "zh-Hans"];

export type UiDict = {
  siteTitle: string;
  metaDesc: string;
  brand: string;
  tagline: string;
  download: string;
  viewOnGithub: string;
  footerTagline: string;
  copyright: string;
  studioName: string;
  langSwitchName: string;
  langSwitchAria: string;
};

export const STUDIO_URL = "https://qzrzz.com/";

export const GITHUB_URL = "https://github.com/qzrzz/QLaunch";
export const DOWNLOAD_URL = "https://github.com/qzrzz/QLaunch/releases/latest";

export const uiDictMap: Record<SupportedLang, UiDict> = {
  en: {
    siteTitle: "QLaunch — Smooth Launchpad Alternative for macOS",
    metaDesc:
      "The smoothest Launchpad for macOS — high-performance, native, free, open source, and powered by Metal.",
    brand: "QLaunch",
    tagline: "The smoothest Launchpad for macOS — high-performance, native, free, open source",
    download: "Download",
    viewOnGithub: "GitHub",
    footerTagline: "The smoothest Launchpad for macOS.",
    copyright: "© 2026",
    studioName: "Qzrzz.com",
    langSwitchName: "English",
    langSwitchAria: "Select language",
  },
  "zh-Hans": {
    siteTitle: "QLaunch — 流畅的启动台 - macOS Launchpad 替代品",
    metaDesc: "最流畅的 macOS 应用启动台，简单、无感、赏心悦目、开源免费，Metal 渲染",
    brand: "QLaunch",
    tagline: "最流畅的 macOS 应用启动台，简单、无感、赏心悦目、开源免费",
    download: "下载",
    viewOnGithub: "GitHub",
    footerTagline: "最流畅的启动台 macOS Launchpad",
    copyright: "© 2026",
    studioName: "Qzrzz.com",
    langSwitchName: "简体中文",
    langSwitchAria: "选择语言",
  },
};
/** 语言切换器展示标签。 */
export const langLabels: Record<SupportedLang, string> = {
  en: "English",
  "zh-Hans": "简体中文",
};

/** 解析当前路径语言（优先 pathname：/zh-Hans/）。 */
export function getCurrentLang(): SupportedLang {
  if (typeof window === "undefined") return "en";
  const path = window.location.pathname;
  if (path.includes("/zh-Hans") || path.includes("/zh")) return "zh-Hans";
  return "en";
}

/** 根据浏览器语言检测偏好。 */
export function detectBrowserLanguage(customLangs?: readonly string[]): SupportedLang {
  let languagesList: readonly string[] = [];

  if (customLangs) {
    languagesList = customLangs;
  } else if (typeof navigator !== "undefined") {
    languagesList = navigator.languages || (navigator.language ? [navigator.language] : []);
  }

  for (const lang of languagesList) {
    const lower = lang.toLowerCase();
    if (lower.startsWith("zh")) return "zh-Hans";
    if (lower.startsWith("en")) return "en";
  }

  return "en";
}

/**
 * 用户首选语言：
 * localStorage > 浏览器语言 > en
 */
export function getPreferredLanguage(): SupportedLang {
  if (typeof window !== "undefined" && typeof localStorage !== "undefined") {
    try {
      const saved = localStorage.getItem(STORAGE_LANG_KEY);
      if (saved === "zh-Hans" || saved === "en") {
        return saved;
      }
    } catch {
      // ignore
    }
  }

  return detectBrowserLanguage();
}

/** 持久化语言偏好。 */
export function setPreferredLanguage(lang: SupportedLang): void {
  if (typeof window !== "undefined" && typeof localStorage !== "undefined") {
    try {
      localStorage.setItem(STORAGE_LANG_KEY, lang);
    } catch {
      // ignore
    }
  }
}

/** @deprecated 使用 setPreferredLanguage */
export function setCurrentLang(lang: SupportedLang): void {
  setPreferredLanguage(lang);
}

/**
 * 根路径自动跳转到首选语言子目录；
 * 已在语言子路径时同步偏好。
 */
export function autoRedirectDefaultLanguage(): boolean {
  if (typeof window === "undefined") return false;

  const path = window.location.pathname;
  const isExplicitSubpath = path.includes("/zh-Hans");

  if (isExplicitSubpath) {
    setPreferredLanguage("zh-Hans");
    return false;
  }

  const preferredLang = getPreferredLanguage();
  if (preferredLang !== "en") {
    const search = window.location.search;
    const hash = window.location.hash;
    window.location.replace(`./${preferredLang}/${search}${hash}`);
    return true;
  }

  return false;
}

/**
 * 计算语言切换目标相对 URL，避免子目录下路径叠加 404。
 */
export function getLangUrl(targetLang: SupportedLang, currentLang?: SupportedLang): string {
  const cur = currentLang || getCurrentLang();

  if (cur === "en") {
    if (targetLang === "en") return "./";
    return `./${targetLang}/`;
  }

  // 当前在非英文子目录
  if (targetLang === "en") return "../";
  if (targetLang === cur) return "./";
  return `../${targetLang}/`;
}

/**
 * 相对站点根的静态资源路径（子目录下加 `../`）。
 * 只取文件名，避免生产 WebP 插件把 JS 字符串改写成 `../xxx.webp` 后再二次拼路径。
 */
export function getRootRelativePath(filename: string, currentLang?: SupportedLang): string {
  const cur = currentLang || getCurrentLang();
  const clean = filename.replaceAll("\\", "/").split("/").filter(Boolean).pop() || filename;
  return cur === "en" ? `./${clean}` : `../${clean}`;
}
