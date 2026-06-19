interface SetupToggleProps {
  active: boolean;
  disabled?: boolean;
  label: string;
  note?: string;
  onClick: () => void;
  valueLabel: string;
}

export function SetupToggle({ active, disabled = false, label, note, onClick, valueLabel }: SetupToggleProps) {
  return (
    <button
      className={active ? "setup-toggle is-active" : "setup-toggle"}
      disabled={disabled}
      onClick={onClick}
      title={note}
      type="button"
    >
      <span>{label}</span>
      <strong>{valueLabel}</strong>
    </button>
  );
}
