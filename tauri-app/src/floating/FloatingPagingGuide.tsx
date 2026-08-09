import type { CSSProperties } from "react";

interface FloatingPagingGuideProps {
  error: string | null;
  saving: boolean;
  showsArrowGlyphs: boolean;
  targetX: number;
  targetY: number;
  onArrowVisibilityChange: (visible: boolean) => void;
  onComplete: () => void;
}

export function FloatingPagingGuide({
  error,
  saving,
  showsArrowGlyphs,
  targetX,
  targetY,
  onArrowVisibilityChange,
  onComplete,
}: FloatingPagingGuideProps) {
  return (
    <div className="floating-paging-guide" role="dialog" aria-label="悬浮窗翻页引导">
      <span className="floating-paging-guide-edge floating-paging-guide-edge--left" aria-hidden="true" />
      <span className="floating-paging-guide-edge floating-paging-guide-edge--right" aria-hidden="true" />
      <span
        className="floating-paging-guide-pointer"
        aria-hidden="true"
        style={{
          "--floating-paging-guide-target-x": `${targetX}px`,
          top: targetY,
        } as CSSProperties}
      />

      <section
        className="floating-paging-guide-card"
        onDoubleClick={(event) => event.stopPropagation()}
        onMouseDown={(event) => event.stopPropagation()}
      >
        <strong>点两侧即可翻页</strong>
        <p>点击阴影边缘试一下</p>
        <div className="floating-paging-guide-actions">
          <label>
            <input
              checked={showsArrowGlyphs}
              disabled={saving}
              onChange={(event) => onArrowVisibilityChange(event.currentTarget.checked)}
              type="checkbox"
            />
            <span>显示箭头</span>
          </label>
          <button disabled={saving} onClick={onComplete} type="button">
            {saving ? "保存中" : "开始体验"}
          </button>
        </div>
        {error ? <small role="alert">{error}</small> : null}
      </section>
    </div>
  );
}
