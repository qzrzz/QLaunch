import qlaunchpadIcon from "../../assets/qlaunchpad-512.png";
import {
  DOWNLOAD_URL,
  GITHUB_URL,
  uiDictMap,
  type SupportedLang,
} from "../../i18n/dict";
import "./Hero.css";

interface HeroProps {
  lang?: SupportedLang;
}

/** 首屏：品牌、标语与下载入口。 */
export function Hero({ lang = "en" }: HeroProps) {
  const dict = uiDictMap[lang] || uiDictMap.en;

  return (
    <section className="hero" aria-labelledby="hero-title">
      <div className="heroInner">
        <img
          className="heroIcon"
          src={qlaunchpadIcon}
          width="96"
          height="96"
          alt=""
          decoding="async"
        />
        <h1 id="hero-title" className="heroTitle">
          {dict.brand}
        </h1>
        <p className="heroTagline">{dict.tagline}</p>
        <div className="heroActions">
          <a
            className="heroPrimaryBtn"
            href={DOWNLOAD_URL}
            target="_blank"
            rel="noreferrer"
          >
            {dict.download}
          </a>
          <a
            className="heroSecondaryBtn"
            href={GITHUB_URL}
            target="_blank"
            rel="noreferrer"
          >
            {dict.viewOnGithub}
          </a>
        </div>
      </div>
    </section>
  );
}
