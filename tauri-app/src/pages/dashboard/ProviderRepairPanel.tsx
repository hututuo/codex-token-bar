import { useState } from "react";
import { ProviderRepairCard } from "../../components/ProviderRepairCard";
import type { ProviderRepairSnapshot } from "../../types/dashboard";
import { buildProviderRepairPanelModel } from "./providerRepairPanelModel";

interface ProviderRepairPanelProps {
  onClose: () => void;
  onSnapshotChange: (snapshot: ProviderRepairSnapshot) => void;
  open: boolean;
  snapshot: ProviderRepairSnapshot;
}

export function ProviderRepairPanel({
  onClose,
  onSnapshotChange,
  open,
  snapshot,
}: ProviderRepairPanelProps) {
  const [closeBlocked, setCloseBlocked] = useState(false);
  const panelModel = buildProviderRepairPanelModel({ closeBlocked, open, snapshot });

  if (!open) {
    return null;
  }

  return (
    <div className="repair-overlay" role="dialog" aria-modal="true" aria-label="会话消失修复">
      <section className="repair-panel">
        <header className="repair-panel-head">
          <div>
            <span>高级修复</span>
            <h2>会话消失修复</h2>
            <p>先扫描并创建完整备份；同步修复只在你确认后执行。</p>
          </div>
          <button
            className="repair-panel-close"
            disabled={panelModel.closeDisabled}
            onClick={onClose}
            title={panelModel.closeTitle}
            type="button"
            aria-label="关闭会话消失修复"
          >
            关闭
          </button>
        </header>

        <ProviderRepairCard
          autoScanOnMount={panelModel.autoScanOnMount}
          id="provider-repair"
          onCloseBlockedChange={setCloseBlocked}
          onSnapshotChange={onSnapshotChange}
          snapshot={snapshot}
        />

        <footer className="repair-panel-foot">
          <span>建议退出 Codex Desktop 后执行同步；运行中的 Codex 可能会重新写回历史索引。</span>
          <span>所有同步都会先创建完整备份，可从备份列表回滚。</span>
        </footer>
      </section>
    </div>
  );
}
