import type { SectionConfig } from "../content";
import { FeatureCard } from "./FeatureCard";

interface FeatureSectionProps {
  section: SectionConfig;
}

/** 通用分区：标题 + 卡片列表，id 自动生成锚点 section-{id}。 */
export function FeatureSection({ section }: FeatureSectionProps) {
  const headingId = `${section.id}-heading`;
  const sectionId = `section-${section.id}`;

  const sectionClasses = ["featureCollection", section.className]
    .filter(Boolean)
    .join(" ");

  return (
    <section
      id={sectionId}
      className={sectionClasses}
      aria-labelledby={headingId}
    >
      <header className="pageSectionHeading">
        <h2 id={headingId}>{section.title}</h2>
        <p>{section.description}</p>
      </header>

      <div className="featureCollection__cards">
        {section.cards.map((card, index) => (
          <FeatureCard
            key={`${section.id}-${card.style ?? "left"}-${card.image ?? index}`}
            card={card}
          />
        ))}
      </div>
    </section>
  );
}
