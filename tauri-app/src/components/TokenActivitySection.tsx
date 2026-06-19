import { useMemo, useState } from "react";
import type { ActivityDay } from "../types/dashboard";
import { ActivityModeSelector } from "./tokenActivity/ActivityModeSelector";
import { HeatmapGrid } from "./tokenActivity/HeatmapGrid";
import {
  buildCalendarDays,
  buildHeatmapDays,
  buildMonthMarkers,
  isInRange,
  summarizeRange,
  type ActivityMode,
} from "./tokenActivity/model";

interface TokenActivitySectionProps {
  days: ActivityDay[];
}

export function TokenActivitySection({ days }: TokenActivitySectionProps) {
  const [mode, setMode] = useState<ActivityMode>("daily");
  const [rangeStart, setRangeStart] = useState<string | null>(null);
  const [rangeEnd, setRangeEnd] = useState<string | null>(null);

  const calendarDays = useMemo(() => buildCalendarDays(days), [days]);
  const heatmapDays = useMemo(() => buildHeatmapDays(calendarDays, mode), [calendarDays, mode]);
  const monthMarkers = useMemo(() => buildMonthMarkers(calendarDays), [calendarDays]);
  const selectedDays = useMemo(
    () => calendarDays.filter((day) => isInRange(day.date, rangeStart, rangeEnd)),
    [calendarDays, rangeEnd, rangeStart],
  );
  const summary = summarizeRange(selectedDays, rangeStart, rangeEnd, mode);

  function chooseDate(date: string) {
    if (rangeStart === null || rangeEnd !== null) {
      setRangeStart(date);
      setRangeEnd(null);
      return;
    }
    if (date < rangeStart) {
      setRangeEnd(rangeStart);
      setRangeStart(date);
    } else {
      setRangeEnd(date);
    }
  }

  return (
    <section className="activity-section" aria-label="Token 活动">
      <div className="section-title-row">
        <h2>Token 活动</h2>
        <ActivityModeSelector mode={mode} onModeChange={setMode} />
      </div>

      <HeatmapGrid
        days={heatmapDays}
        mode={mode}
        monthMarkers={monthMarkers}
        onDateSelect={chooseDate}
        rangeEnd={rangeEnd}
        rangeStart={rangeStart}
      />

      <div className="range-summary">
        <span>{summary.hint}</span>
        <strong>{summary.value}</strong>
      </div>
    </section>
  );
}
