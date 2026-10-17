import {
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type FocusEvent,
  type KeyboardEvent,
} from "react";
import { cellColor, cellLabel, isInRange, modelCellColor, modelCostCellBackground, type ActivityMode, type HeatmapDay, type MonthMarker } from "./model";
import type { OfficialAPIPriceModel } from "../../settings/quotaPriceModel";
import {
  heatmapKeyboardAction,
  resolveHeatmapFocusDate,
  selectHeatmapDate,
} from "./heatmapNavigation";

interface HeatmapGridProps {
  accessibleLabel?: string;
  cellPresentation?: (day: HeatmapDay["day"]) => { label: string; background: string; className?: string };
  days: HeatmapDay[];
  mode: ActivityMode;
  modelCostDataAvailable?: boolean;
  priceModel: OfficialAPIPriceModel;
  monthMarkers: MonthMarker[];
  onDateSelect: (date: string) => void;
  onDayHover: (day: HeatmapDay["day"] | null) => void;
  hoveredDate: string | null;
  rangeEnd: string | null;
  rangeStart: string | null;
}

export function HeatmapGrid({
  accessibleLabel = "过去一年 Token 活动热图；使用方向键移动，Enter 或空格选择日期",
  cellPresentation,
  days,
  mode,
  modelCostDataAvailable = true,
  priceModel,
  monthMarkers,
  onDateSelect,
  onDayHover,
  hoveredDate,
  rangeEnd,
  rangeStart,
}: HeatmapGridProps) {
  // A short leading month can share a week with the next month. Keep the
  // later label when there is not enough room for both on the same row.
  const visibleMonthMarkers = monthMarkers.filter((marker, index) => {
    const next = monthMarkers[index + 1];
    return !next || next.column - marker.column >= 2;
  });
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

  useLayoutEffect(() => {
    if (focusedDate !== validFocusedDate) {
      setFocusedDate(validFocusedDate);
    }
    if (
      !focusedCellWasRemoved
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
  }, [focusedCellWasRemoved, focusedDate, validFocusedDate]);

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
        aria-label={accessibleLabel}
        className="heatmap-grid"
        onBlurCapture={handleGridBlur}
        onFocusCapture={() => {
          gridHasFocusRef.current = true;
        }}
        ref={gridRef}
        role="group"
      >
        {days.map(({ day, intensity }, index) => {
          const presentation = cellPresentation?.(day);
          const selected = isInRange(day.date, rangeStart, rangeEnd);
          const hovered = hoveredDate === day.date;
          const classes = [
            "heatmap-cell",
            selected ? "heatmap-cell--selected" : "",
            hovered ? "heatmap-cell--hovered" : "",
            presentation?.className,
          ].filter(Boolean).join(" ");
          return (
            <button
              aria-label={presentation?.label ?? cellLabel(day, mode, priceModel, modelCostDataAvailable)}
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
              style={{
                background: presentation?.background ?? (mode === "modelCost"
                  ? modelCostCellBackground(day, intensity, priceModel, modelCostDataAvailable)
                  : mode === "model"
                    ? modelCellColor(day, intensity)
                    : cellColor(mode, intensity)),
              }}
              tabIndex={validFocusedDate === day.date ? 0 : -1}
              title={presentation?.label ?? cellLabel(day, mode, priceModel, modelCostDataAvailable)}
              type="button"
            />
          );
        })}
      </div>
      <div className="heatmap-months" aria-hidden="true">
        {visibleMonthMarkers.map((marker) => (
          <span
            key={`${marker.label}-${marker.column}`}
            style={{
              gridColumn: `${marker.column} / span ${Math.min(2, 54 - marker.column)}`,
              gridRow: 1,
              justifySelf: marker.column === 53 ? "end" : undefined,
            }}
          >
            {marker.label}
          </span>
        ))}
      </div>
    </>
  );
}
