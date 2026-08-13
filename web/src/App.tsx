import { useEffect } from "react";
import { FeatureSection } from "./components/FeatureSection";
import { getSectionsContent } from "./content";
import { Footer } from "./Feature/Footer";
import { StickyHeader } from "./Feature/Header";
import { Hero } from "./Feature/Hero";
import heroVideoAv1 from "./assets/v1-av1.mp4";
import heroVideo from "./assets/v1.mp4";
import heroVideoPoster from "./assets/v1-p.png";
import {
  autoRedirectDefaultLanguage,
  getCurrentLang,
  uiDictMap,
  type SupportedLang,
} from "./i18n/dict";

interface AppProps {
  lang?: SupportedLang;
}

/** QLaunch 产品官网首页：Header → Hero → 内容分区 → Footer。 */
export function App({ lang }: AppProps) {
  useEffect(() => {
    autoRedirectDefaultLanguage();
  }, []);

  const currentLang = lang || getCurrentLang();
  const sections = getSectionsContent(currentLang);
  const dict = uiDictMap[currentLang] || uiDictMap.en;

  useEffect(() => {
    document.documentElement.lang = currentLang === "zh-Hans" ? "zh-Hans" : "en";
    document.title = dict.siteTitle;
    const meta = document.querySelector('meta[name="description"]');
    if (meta) {
      meta.setAttribute("content", dict.metaDesc);
    }
  }, [currentLang, dict.metaDesc, dict.siteTitle]);

  return (
    <main className="homePage" id="top">
      <StickyHeader lang={currentLang} />
      <Hero lang={currentLang} />

      <div className="heroVideo">
        <video
          className="heroVideo__media"
          poster={heroVideoPoster}
          autoPlay
          loop
          muted
          playsInline
          preload="metadata"
          aria-label="QLaunch product preview"
        >
          <source src={heroVideoAv1} type='video/mp4; codecs="av01"' />
          <source src={heroVideo} type="video/mp4" />
        </video>
      </div>

      {sections.map((section) => (
        <FeatureSection key={section.id} section={section} />
      ))}

      <Footer lang={currentLang} />
    </main>
  );
}
