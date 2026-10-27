import { activityModes, type ActivityMode } from "./model";

interface ActivityModeSelectorProps {
  mode: ActivityMode;
  tokensOnly?: boolean;
  onModeChange: (mode: ActivityMode) => void;
}

export function ActivityModeSelector({ mode, onModeChange, tokensOnly = false }: ActivityModeSelectorProps) {
  return (
    <div className="segmented segmented--activity" role="group" aria-label="Token 活动模式">
      {activityModes.filter(item => !tokensOnly || ["daily", "weekly", "cumulative"].includes(item.id)).map((item) => (
        <button
          aria-pressed={item.id === mode}
          className={item.id === mode ? "active" : undefined}
          key={item.id}
          onClick={() => onModeChange(item.id)}
          type="button"
        >
          {item.label}
        </button>
      ))}
    </div>
  );
}
