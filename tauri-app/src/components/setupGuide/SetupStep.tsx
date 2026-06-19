import type { ReactNode } from "react";

interface SetupStepProps {
  index: string;
  ok?: boolean;
  title: string;
  status: string;
  children: ReactNode;
}

export function SetupStep({ index, ok = true, title, status, children }: SetupStepProps) {
  return (
    <section className="setup-step">
      <div className={ok ? "setup-step-index is-ok" : "setup-step-index"}>{ok ? "✓" : index}</div>
      <div className="setup-step-body">
        <div className="setup-step-title">
          <strong>{title}</strong>
          <span>{status}</span>
        </div>
        {children}
      </div>
    </section>
  );
}
