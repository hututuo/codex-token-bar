import {
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type FocusEvent,
  type KeyboardEvent,
} from "react";
import { cellColor, cellLabel, isInRange, type ActivityMode, type HeatmapDay, type MonthMarker } from "./model";
import {
  heatmapKeyboardAction,
  resolveHeatmapFocusDate,
  selectHeatmapDate,
} from "./heatmapNavigation";

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
  const dates = useMemo(() => days.map(({ day }) => day.date), [days]);
  const [focusedDate, setFocusedDate] = useState<string | null>(() => (
    resolveHeatmapFocusDate(dates, null, hoveredDate, rangeStart)
  ));
  const gridRef = useRef<HTMLDivElement>(null);
  const gridHasFocusRef = useRef(false);
  const cellRefs = useRef(new Map<string, HTMLButtonElement>());
  const validFocusedDate = resolveHeatmapFocusDate(
    dates,
    focusedDate,
    hoveredDate,
    rangeStart,
  );
  const focusedCellWasRemoved = focusedDate !== null && !dates.includes(focusedDate);
  const shouldRestoreRemovedFocus = focusedCellWasRemoved && gridHasFocusRef.current;

  useLayoutEffect(() => {
    if (focusedDate !== validFocusedDate) {
      setFocusedDate(validFocusedDate);
    }
    if (
      !shouldRestoreRemovedFocus
      || !gridHasFocusRef.current
      || validFocusedDate === null
    ) {
      return;
    }
    const grid = gridRef.current;
    if (!grid) {
      return;
    }
    const activeElement = grid.ownerDocument.activeElement;
    if (activeElement !== null
      && activeElement !== grid.ownerDocument.body
      && !grid.contains(activeElement)) {
      return;
    }
    cellRefs.current.get(validFocusedDate)?.focus();
  }, [focusedDate, shouldRestoreRemovedFocus, validFocusedDate]);

  function handleGridBlur(event: FocusEvent<HTMLDivElement>) {
    const nextTarget = event.relatedTarget as Node | null;
    if (nextTarget === null || !event.currentTarget.contains(nextTarget)) {
      gridHasFocusRef.current = false;
    }
  }

  function handleCellKeyDown(
    event: KeyboardEvent<HTMLButtonElement>,
    index: number,
    date: string,
  ) {
    const action = heatmapKeyboardAction(event.key, index, days.length);
    if (!action.handled) {
      return;
    }
    event.preventDefault();
    if (action.select) {
      selectHeatmapDate(date, onDateSelect);
      return;
    }
    const nextDay = days[action.index]?.day;
    if (!nextDay) {
      return;
    }
    setFocusedDate(nextDay.date);
    cellRefs.current.get(nextDay.date)?.focus();
  }

  return (
    <>
      <div
        aria-label="过去一年 Token 活动热图；使用方向键移动，Enter 或空格选择日期"
        className="heatmap-grid"
        onBlurCapture={handleGridBlur}
        onFocusCapture={() => {
          gridHasFocusRef.current = true;
        }}
        ref={gridRef}
        role="group"
      >
        {days.map(({ day, intensity }, index) => {
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
              onClick={() => selectHeatmapDate(day.date, onDateSelect)}
              onFocus={() => {
                setFocusedDate(day.date);
                onDayHover(day);
              }}
              onKeyDown={(event) => handleCellKeyDown(event, index, day.date)}
              onMouseEnter={() => onDayHover(day)}
              onMouseLeave={() => onDayHover(null)}
              onBlur={() => onDayHover(null)}
              ref={(node) => {
                if (node) {
                  cellRefs.current.set(day.date, node);
                } else {
                  cellRefs.current.delete(day.date);
                }
              }}
              style={{ backgroundColor: cellColor(mode, intensity) }}
              tabIndex={validFocusedDate === day.date ? 0 : -1}
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
