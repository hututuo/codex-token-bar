import type { CSSProperties } from "react";
import type { FloatingGuidePage } from "./floatingSettings";
import {
  FLOATING_RUNNING_MODEL_GUIDE_DEMO,
  FloatingRunningThreadModelDetails,
} from "./FloatingRunningThreadModelDetails";

interface FloatingPagingGuideProps {
  page: FloatingGuidePage;
  isLastPage: boolean;
  error: string | null;
  saving: boolean;
  showsArrowGlyphs: boolean;
  targetX: number;
  targetY: number;
  pointerY: number;
  targetYs?: number[];
  pointerYs?: number[];
  calloutY: number;
  calloutCardY: number;
  showDemoModelUsage?: boolean;
  modelTargetX: number;
  modelTargetY: number;
  modelTargetWidth: number;
  onArrowVisibilityChange: (visible: boolean) => void;
  onAdvance: () => void;
}

export function FloatingPagingGuide({
  page,
  isLastPage,
  error,
  saving,
  showsArrowGlyphs,
  targetX,
  targetY,
  pointerY,
  targetYs = [targetY],
  pointerYs = [pointerY],
  calloutY,
  calloutCardY,
  showDemoModelUsage = false,
  modelTargetX,
  modelTargetY,
  modelTargetWidth,
  onArrowVisibilityChange,
  onAdvance,
}: FloatingPagingGuideProps) {
  if (page === "runningModels") {
    return (
      <div className="floating-paging-guide floating-paging-guide--running-models" role="dialog" aria-label="运行模型详情引导">
        <span
          className="floating-running-model-guide-target"
          aria-hidden="true"
          style={{
            left: modelTargetX,
            top: modelTargetY,
            width: modelTargetWidth,
          }}
        />
        <span
          className="floating-running-model-guide-pointer"
          aria-hidden="true"
          style={{ left: modelTargetX + 8, top: modelTargetY + 8 }}
        />
        <span
          className="floating-running-model-guide-connector"
          aria-hidden="true"
          style={{
            "--floating-running-model-target-right": `${modelTargetX + modelTargetWidth / 2}px`,
            "--floating-running-model-guide-y": `${modelTargetY}px`,
          } as CSSProperties}
        />
        <FloatingRunningThreadModelDetails
          className="floating-running-model-details--guide"
          demo
          summary={FLOATING_RUNNING_MODEL_GUIDE_DEMO}
        />
        <section
          className="floating-paging-guide-card floating-paging-guide-card--running-models"
          onDoubleClick={(event) => event.stopPropagation()}
        >
          <strong>点击“主 / 子”查看模型</strong>
          <p>右侧会显示模型、思考强度和数量；再点一次即可收起</p>
          <GuideAdvanceButton isLastPage={isLastPage} saving={saving} onAdvance={onAdvance} />
          {error ? <small role="alert">{error}</small> : null}
        </section>
      </div>
    );
  }

  return (
    <div className="floating-paging-guide" role="dialog" aria-label="悬浮窗翻页引导">
      <span className="floating-paging-guide-edge floating-paging-guide-edge--left" aria-hidden="true" />
      <span className="floating-paging-guide-edge floating-paging-guide-edge--right" aria-hidden="true" />
      {showsArrowGlyphs ? targetYs.map((rowY) => (
        <div key={`arrow-${rowY}`} aria-hidden="true">
          <span
            className="floating-paging-guide-arrow-cue floating-paging-guide-arrow-cue--left"
            style={{ top: rowY }}
          />
          <span
            className="floating-paging-guide-arrow-cue floating-paging-guide-arrow-cue--right"
            style={{ top: rowY }}
          />
        </div>
      )) : null}
      {pointerYs.map((rowY) => (
        <span
          className="floating-paging-guide-pointer"
          key={`pointer-${rowY}`}
          aria-hidden="true"
          style={{
            "--floating-paging-guide-target-x": `${targetX}px`,
            top: rowY,
          } as CSSProperties}
        />
      ))}

      <span
        className="floating-paging-guide-callout-arrow"
        aria-hidden="true"
        style={{ top: calloutY }}
      />
      <aside
        className="floating-paging-guide-callout"
        aria-label="7d余量与均速差值说明"
        style={{ top: calloutCardY }}
      >
        <img
          className="floating-paging-guide-quota-graphic"
          src="/floating-quota-pace-guide.png"
          alt="7d 余量与均速差值示意：实际剩余比按均速应剩多出来的部分，就是余量领先"
          draggable={false}
        />
      </aside>

      <section
        className="floating-paging-guide-card"
        onDoubleClick={(event) => event.stopPropagation()}
      >
        <strong>点两侧即可翻页</strong>
        <p>点击阴影边缘试一下</p>
        {showDemoModelUsage ? (
          <small className="floating-paging-guide-demo" title="仅用于引导展示，不会写入真实统计">
            悬浮窗数据为示例
          </small>
        ) : null}
        <div className="floating-paging-guide-actions">
          <label onMouseDown={(event) => event.stopPropagation()}>
            <input
              checked={showsArrowGlyphs}
              disabled={saving}
              onChange={(event) => onArrowVisibilityChange(event.currentTarget.checked)}
              type="checkbox"
            />
            <span>显示翻页箭头</span>
          </label>
          <GuideAdvanceButton isLastPage={isLastPage} saving={saving} onAdvance={onAdvance} />
        </div>
        {error ? <small role="alert">{error}</small> : null}
      </section>
    </div>
  );
}

function GuideAdvanceButton({
  isLastPage,
  saving,
  onAdvance,
}: {
  isLastPage: boolean;
  saving: boolean;
  onAdvance: () => void;
}) {
  return (
    <button
      disabled={saving}
      onClick={onAdvance}
      onMouseDown={(event) => event.stopPropagation()}
      type="button"
    >
      {saving ? "保存中" : (isLastPage ? "开始体验" : "下一步")}
    </button>
  );
}
