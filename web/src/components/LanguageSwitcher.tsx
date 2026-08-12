import { useEffect, useRef, useState } from "react";
import {
  getCurrentLang,
  getLangUrl,
  langLabels,
  setPreferredLanguage,
  SUPPORTED_LANGS,
  uiDictMap,
  type SupportedLang,
} from "../i18n/dict";
import "./LanguageSwitcher.css";

interface LanguageSwitcherProps {
  currentLang?: SupportedLang;
}

/** 下拉式语言切换。 */
export function LanguageSwitcher({ currentLang }: LanguageSwitcherProps) {
  const [isOpen, setIsOpen] = useState(false);
  const activeLang = currentLang || getCurrentLang();
  const dict = uiDictMap[activeLang] || uiDictMap.en;
  const dropdownRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
        setIsOpen(false);
      }
    }
    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, []);

  return (
    <div className="langDropdown" ref={dropdownRef}>
      <button
        type="button"
        className={`langDropdownTrigger ${isOpen ? "langDropdownTrigger--open" : ""}`}
        onClick={() => setIsOpen(!isOpen)}
        aria-expanded={isOpen}
        aria-label={dict.langSwitchAria}
      >
        <GlobeIcon />
        <span>{langLabels[activeLang]}</span>
        <ChevronIcon className={`langChevron ${isOpen ? "langChevron--open" : ""}`} />
      </button>

      {isOpen && (
        <div className="langDropdownMenu" role="menu">
          {SUPPORTED_LANGS.map((code) => {
            const isActive = code === activeLang;
            return (
              <a
                key={code}
                className={`langDropdownItem ${isActive ? "langDropdownItem--active" : ""}`}
                href={getLangUrl(code, activeLang)}
                hrefLang={code}
                role="menuitem"
                onClick={() => {
                  setPreferredLanguage(code);
                  setIsOpen(false);
                }}
              >
                <span>{langLabels[code]}</span>
                {isActive ? <CheckIcon /> : null}
              </a>
            );
          })}
        </div>
      )}
    </div>
  );
}

function GlobeIcon() {
  return (
    <svg
      className="langIcon"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="10" />
      <line x1="2" y1="12" x2="22" y2="12" />
      <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10z" />
    </svg>
  );
}

function ChevronIcon({ className }: { className?: string }) {
  return (
    <svg
      className={className || "langChevron"}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <polyline points="6 9 12 15 18 9" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg
      className="langCheck"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <polyline points="20 6 9 17 4 12" />
    </svg>
  );
}
