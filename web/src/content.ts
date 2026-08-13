import type { SupportedLang } from "./i18n/dict";
import ImageS1 from "./assets/s1.png";
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
        "相比同类工具操作更加流畅、更高画质显示图标。120Hz 响应、Display P3 高色域、Liquid Glass、过渡动画、拼音搜索。高质量的实现最简单的核心功能，让你感觉不到它的存在。",
      cards: [{ style: "center", image: ImageS1 }],
    },

    {
      id: "what",
      title: "QLaunch 是什么",
      description:
        "QLaunch 是 macOS 应用启动台 —— 展示系统中的应用程序，并启动他们。 macOS 从 26 开始遗弃了 Launchpad，并试图用小小的 Spotlight 搜索框取代它，但我们喜欢整页精美的应用程序图标带来的赏心悦目的体验",
      cards: [{ style: "center", image: ImageS1 }],
    },
    {
      id: "performance",
      title: "Metal 高性能 GPU 渲染",
      description:
        "QLaunch 使用 Metal 直接调用 GPU 进行图像渲染，实现最高可达 120 Hz 的响应速度，和超越同类工具的图像质量。",
      cards: [],
    },
    {
      id: "glass",
      title: "Liquid Glass",
      description: "适配最新 macOS 的液态玻璃 UI 效果",
      cards: [],
    },

    {
      id: "pingyin",
      title: "拼音搜索",
      description: "中文用户不用切换输入法了，无脑输入，无论当前输入法是英文还是拼音都能搜索到目标",
      cards: [],
    },

    {
      id: "ai",
      title: "AI 帮你整理应用，开放且免费",
      description: "能让 AI 帮你整理应用程序，不是内置的付费功能，而是开放接口给你自己的 AI 调用",
      cards: [],
    },

    {
      id: "open",
      title: "高质量核心功能，剩下的交给你  Vibe Coding",
      description: "需要更多功能，开源代码让你的 AI Agent 去实现吧",
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
