import type { FeatureCardConfig } from "../content";

interface FeatureCardProps {
  card: FeatureCardConfig;
}

/**
 * 通用功能卡片：只展示 image，按 style 布局。
 * image 默认按 2x 资源通过 srcSet 声明。
 */
export function FeatureCard({ card }: FeatureCardProps) {
  const { image, style = "left" } = card;

  const containerClasses = [
    "featureCard",
    `featureCard--${style}`,
    !image ? "featureCard--placeholder" : null,
  ]
    .filter(Boolean)
    .join(" ");

  return (
    <article className={containerClasses}>
      {image ? (
        <div className="featureCard__media">
          <img
            className="featureCard__shot"
            src={image}
            srcSet={`${image} 2x`}
            alt=""
            decoding="async"
          />
        </div>
      ) : (
        <div className="featureCard__media featureCard__media--empty" aria-hidden="true">
          <span className="featureCard__placeholderLabel">{style}</span>
        </div>
      )}
    </article>
  );
}
