import { activityModes, type ActivityMode } from "./model";

interface ActivityModeSelectorProps {
  mode: ActivityMode;
  onModeChange: (mode: ActivityMode) => void;
}

export function ActivityModeSelector({ mode, onModeChange }: ActivityModeSelectorProps) {
  return (
    <div className="segmented segmented--activity" role="group" aria-label="Token 活动模式">
      {activityModes.map((item) => (
        <button
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
