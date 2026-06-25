import { cellColor, cellLabel, isInRange, type ActivityMode, type HeatmapDay, type MonthMarker } from "./model";

interface HeatmapGridProps {
  days: HeatmapDay[];
  mode: ActivityMode;
  monthMarkers: MonthMarker[];
  onDateSelect: (date: string) => void;
  onDayHover: (day: HeatmapDay["day"] | null) => void;
  hoveredDate: string | null;
  rangeEnd: string | null;
  rangeStart: string | null;
}

export function HeatmapGrid({
  days,
  mode,
  monthMarkers,
  onDateSelect,
  onDayHover,
  hoveredDate,
  rangeEnd,
  rangeStart,
}: HeatmapGridProps) {
  return (
    <>
      <div className="heatmap-grid">
        {days.map(({ day, intensity }) => {
          const selected = isInRange(day.date, rangeStart, rangeEnd);
          const hovered = hoveredDate === day.date;
          const classes = [
            "heatmap-cell",
            selected ? "heatmap-cell--selected" : "",
            hovered ? "heatmap-cell--hovered" : "",
          ].filter(Boolean).join(" ");
          return (
            <button
              aria-label={cellLabel(day, mode)}
              aria-pressed={selected}
              className={classes}
              key={day.date}
              onClick={() => onDateSelect(day.date)}
              onFocus={() => onDayHover(day)}
              onMouseEnter={() => onDayHover(day)}
              onMouseLeave={() => onDayHover(null)}
              onBlur={() => onDayHover(null)}
              style={{ backgroundColor: cellColor(mode, intensity) }}
              title={cellLabel(day, mode)}
              type="button"
            />
          );
        })}
      </div>
      <div className="heatmap-months" aria-hidden="true">
        {monthMarkers.map((marker) => (
          <span key={`${marker.label}-${marker.column}`} style={{ gridColumn: `${marker.column} / span 4` }}>
            {marker.label}
          </span>
        ))}
      </div>
    </>
  );
}
