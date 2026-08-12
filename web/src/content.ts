import type { SupportedLang } from "./i18n/dict";

/**
 * 卡片布局：
 * - left   媒体偏左（默认）
 * - right  媒体偏右
 * - bottom 媒体偏下
 * - center 图片水平垂直居中
 */
export type CardStyle = "left" | "right" | "bottom" | "center";

/** 功能卡片：只需图片与布局。 */
export interface FeatureCardConfig {
  /**
   * 截图 / 合成图（import 或 public 路径）。
   * 默认按 **2x** 资源渲染：`srcSet="${image} 2x"`。
   */
  image?: string;
  /** 布局样式 */
  style?: CardStyle;
}

/** 首页分区配置 */
export interface SectionConfig {
  /** 分区 ID（锚点：#section-{id}） */
  id: string;
  /** 分区标题 */
  title: string;
  /** 分区说明 */
  description: string;
  /** 分区内卡片 */
  cards: FeatureCardConfig[];
  /** 分区自定义 class */
  className?: string;
}

/**
 * 多语言全站内容。
 * 卡片只配 image + style；文案按语言维护。
 * 营销截图放入 src/shots/ 后在此 import 并挂到 cards。
 */
export const sectionsContentMap: Record<SupportedLang, SectionConfig[]> = {
  en: [
    {
      id: "why",
      title: "Why QLaunch",
      description:
        "macOS removed the classic Launchpad feel. QLaunch brings it back — native AppKit + Metal, 128pt icons, smooth paging, and a calm liquid-glass UI.",
      cards: [],
    },
    {
      id: "performance",
      title: "Metal Performance",
      description:
        "Icons and labels are drawn with Metal atlases and CADisplayLink up to 120fps. Spring paging, rubber-band edges, and open/close scale+fade stay buttery smooth.",
      cards: [],
    },
    {
      id: "glass",
      title: "Wallpaper Blur & Liquid Glass",
      description:
        "Reads your desktop wallpaper, applies true CIGaussianBlur with vignette. Search uses macOS liquid glass where available, with a careful material fallback on older systems.",
      cards: [],
    },
  ],

  "zh-Hans": [
    {
      id: "why",
      title: "为什么选择 QLaunch",
      description:
        "系统 Launchpad 不再顺手？QLaunch 用原生 AppKit + Metal 把它找回来——128pt 图标、流畅翻页、安静的液态玻璃界面。",
      cards: [],
    },
    {
      id: "performance",
      title: "Metal 高性能",
      description:
        "图标与标签走 Metal atlas，CADisplayLink 最高 120fps。弹簧翻页、边缘橡胶回弹、开合缩放淡入，全程顺滑。",
      cards: [],
    },
    {
      id: "glass",
      title: "壁纸模糊与液态玻璃",
      description:
        "读取当前桌面壁纸，CIGaussianBlur 真模糊 + vignette。搜索框在新系统使用液态玻璃，旧系统用分层 material 精心近似。",
      cards: [],
    },
  ],
};

/** 根据语言获取分区列表。 */
export function getSectionsContent(lang: SupportedLang): SectionConfig[] {
  return sectionsContentMap[lang] || sectionsContentMap.en;
}

/** 导航用的分区摘要（Header 锚点等）。 */
export function getSectionNav(
  lang: SupportedLang,
): Array<{ id: string; title: string; href: string }> {
  return getSectionsContent(lang).map((section) => ({
    id: section.id,
    title: section.title,
    href: `#section-${section.id}`,
  }));
}
