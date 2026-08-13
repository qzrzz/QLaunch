import qlaunchpadIcon from "../../assets/qlaunchpad-icon.png";
import { LanguageSwitcher } from "../../components/LanguageSwitcher";
import { getSectionsContent } from "../../content";
import { DownloadAnchor } from "../../download";
import { GITHUB_URL, uiDictMap, type SupportedLang } from "../../i18n/dict";
import "./StickyHeader.css";

interface StickyHeaderProps {
  lang?: SupportedLang;
}

/** 顶部导航：品牌 + Why QLaunch + Download / GitHub + 语言切换。 */
export function StickyHeader({ lang = "en" }: StickyHeaderProps) {
  const dict = uiDictMap[lang] || uiDictMap.en;
  const whySection = getSectionsContent(lang).find((s) => s.id === "why");
  const whyTitle = whySection?.title ?? (lang === "zh-Hans" ? "为什么选择 QLaunch" : "Why QLaunch");

  return (
    <header className="stickyHeader">
      <a className="stickyHeaderBrand" href="#top">
        <img src={qlaunchpadIcon} width="28" height="28" alt="" />
        <span>{dict.brand}</span>
      </a>

      <div className="stickyHeaderActions">
        <nav className="stickyHeaderNav" aria-label="Primary">
          <a className="stickyHeaderLink" href="#section-why">
            {whyTitle}
          </a>

          <a
            className="stickyHeaderLink stickyHeaderLink--external"
            href={GITHUB_URL}
            target="_blank"
            rel="noreferrer"
          >
            {dict.viewOnGithub}
          </a>

          <DownloadAnchor className="stickyHeaderLink stickyHeaderLink--action">
            {dict.download}
          </DownloadAnchor>
        </nav>
        <LanguageSwitcher currentLang={lang} />
      </div>
    </header>
  );
}
