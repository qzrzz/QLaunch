import qlaunchpadIcon from "../../assets/qlaunchpad-icon.png";
import {
  DOWNLOAD_URL,
  GITHUB_URL,
  STUDIO_URL,
  uiDictMap,
  type SupportedLang,
} from "../../i18n/dict";
import "./Footer.css";

interface FooterProps {
  lang?: SupportedLang;
}

/** 页脚。 */
export function Footer({ lang = "en" }: FooterProps) {
  const dict = uiDictMap[lang] || uiDictMap.en;

  return (
    <footer className="siteFooter">
      <div className="siteFooterInner">
        <a className="siteFooterBrand" href="#top">
          <img src={qlaunchpadIcon} width="28" height="28" alt="" />
          <span>{dict.brand}</span>
        </a>
        <p className="siteFooterTagline">{dict.footerTagline}</p>
        <div className="siteFooterLinks">
          <a href={GITHUB_URL} target="_blank" rel="noreferrer">
            {dict.viewOnGithub}
          </a>
          <a href={DOWNLOAD_URL} target="_blank" rel="noreferrer">
            {dict.download}
          </a>
        </div>
        <p className="siteFooterCopyright">
          <span>{dict.copyright}</span>{" "}
          <a
            className="siteFooterStudio"
            href={STUDIO_URL}
            target="_blank"
            rel="noreferrer"
          >
            {dict.studioName}
          </a>
        </p>
      </div>
    </footer>
  );
}
