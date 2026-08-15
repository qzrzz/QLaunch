import { IPageMeta, ISection, IQPageConfig } from "qpage";

export const config: IQPageConfig = {
  defaultLang: "zh-Hans",
};

import UrlIcon from "./icons/qlaunchpad-512.png";
import UrlIconFull from "./icons/qlaunchpad-icon-full-128.png";

import UrlMainScreenshotImage from "./assets/v1.png";
import UrlMainScreenshotVideo from "./assets/v1.mp4";

export const page: IPageMeta = {
  productTitle: "QLaunch",
  productTitleCN: "启动台",
  tagline: "最流畅的 macOS 应用启动台，简单、无感、赏心悦目、开源免费",
  taglineShort: "最流畅的 macOS 应用启动台",
  platforms:["macos"],
  icon: UrlIcon,
  iconFull: UrlIconFull,
  metaDesc: "最流畅的 macOS 应用启动台，简单、无感、赏心悦目、开源免费，Metal 渲染",
  githubRepo: "https://github.com/qzrzz/QLaunch",
  onlineUrl: "https://qzrzz.com/QLaunch",
  downloadBase: "https://download.qzrzz.com/qlaunch",
  mainScreenshotImage: UrlMainScreenshotImage,
  mainScreenshotVideo: UrlMainScreenshotVideo,
};

export const sections: ISection[] = [
  {
    id: "why",
    title: "为什么选择 QLaunch",
    isNav: true,
    description:
      "相比同类工具操作更加流畅、更高画质渲染。120Hz 帧率、Display-P3 高色域、Liquid Glass、过渡动画、拼音搜索。高质量的实现最简单的核心功能，让你感觉不到它的存在。",
    cards: [{ image: "./assets/s1.png", style: "center" }],
  },

  {
    id: "what",
    title: "QLaunch 是什么",
    description:
      "QLaunch 是 macOS 应用启动台 —— 展示系统中的应用程序，并启动他们。 macOS 从 26 开始遗弃了 Launchpad，并试图用小小的 Spotlight 搜索框取代它，但我们喜欢整页精美的应用程序图标带来的赏心悦目的体验",
    cards: [{ image: "./assets/s2.png", style: "center" }],
  },

  {
    id: "performance",
    title: "Metal 高性能 GPU 渲染",
    description:
      "QLaunch 使用 Metal 直接调用 GPU 进行图像渲染，实现最高可达 120 Hz 的响应速度，还有超越同类工具的图像质量。",
    cards: [{ image: "./assets/s3.png", style: "center" }],
  },

  {
    id: "pingyin",
    title: "拼音搜索",
    description: "中文用户不用切换输入法了，无脑输入，无论当前输入法是英文还是拼音都能搜索到目标",
    cards: [{ style: "center", image: "./assets/s6.png" }],
  },

  {
    id: "ai",
    title: "AI 帮你整理应用，开放且免费",
    description: "能让 AI 帮你整理应用程序，不是内置的付费功能，而是开放接口给你自己的 AI 调用",
    cards: [{ style: "center", image: "./assets/s5.png" }],
  },

  {
    id: "open",
    title: "高质量核心功能，剩下的交给你  Vibe Coding",
    description: "需要更多功能，开源代码让你的 AI Agent 去实现吧",
    cards: [],
  },
];
