import type { ProviderRepairSnapshot } from "../types/dashboard";

interface ProviderRepairCardProps {
  snapshot: ProviderRepairSnapshot;
}

export function ProviderRepairCard({ snapshot }: ProviderRepairCardProps) {
  return (
    <section className="repair-card" aria-label="会话消失修复">
      <div className="section-title-row">
        <div>
          <h2>会话消失修复</h2>
          <span>
            provider {snapshot.detectedProvider} · {snapshot.providerSource} · {snapshot.sessionFilesFound} 个会话文件
          </span>
        </div>
        <button className="toolbar-button" type="button">
          打开修复
        </button>
      </div>
      <p className={snapshot.inconsistentCount > 0 ? "repair-status repair-status--warn" : "repair-status"}>
        {snapshot.status}
      </p>

      <div className="repair-steps">
        {snapshot.steps.map((step, index) => (
          <div className={step.done ? "repair-step repair-step--done" : "repair-step"} key={step.label}>
            <strong>{index + 1}</strong>
            <span>{step.label}</span>
            <em>{step.status}</em>
          </div>
        ))}
      </div>
    </section>
  );
}
