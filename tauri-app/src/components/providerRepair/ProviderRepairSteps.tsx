import type { ProviderRepairStep } from "../../types/dashboard";

interface ProviderRepairStepsProps {
  steps: ProviderRepairStep[];
}

export function ProviderRepairSteps({ steps }: ProviderRepairStepsProps) {
  return (
    <div className="repair-steps">
      {steps.map((step, index) => (
        <div className={step.done ? "repair-step repair-step--done" : "repair-step"} key={step.label}>
          <strong>{index + 1}</strong>
          <span>{step.label}</span>
          <em>{step.status}</em>
        </div>
      ))}
    </div>
  );
}
