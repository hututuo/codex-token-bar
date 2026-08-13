import { useEffect, useMemo, useState } from "react";
import type { ActivityDay } from "../types/dashboard";
import { ActivityModeSelector } from "./tokenActivity/ActivityModeSelector";
import { HeatmapGrid } from "./tokenActivity/HeatmapGrid";
import {
  buildCalendarDays,
  buildHeatmapDays,
  buildMonthMarkers,
  hoverSummary,
  isInRange,
  summarizeRange,
  type ActivityMode,
} from "./tokenActivity/model";
import {
  isOfficialAPIPriceModel,
  QUOTA_PRICE_MODEL_EVENT,
  readStoredQuotaPriceModel,
  type OfficialAPIPriceModel,
} from "../settings/quotaPriceModel";

interface TokenActivitySectionProps {
  days: ActivityDay[];
  modelCostDataAvailable?: boolean;
}

export function TokenActivitySection({ days, modelCostDataAvailable = true }: TokenActivitySectionProps) {
  const [mode, setMode] = useState<ActivityMode>("daily");
  const [rangeStart, setRangeStart] = useState<string | null>(null);
  const [rangeEnd, setRangeEnd] = useState<string | null>(null);
  const [hoveredDay, setHoveredDay] = useState<ActivityDay | null>(null);
  const [priceModel, setPriceModel] = useState<OfficialAPIPriceModel>("gpt56Sol");

  const calendarDays = useMemo(() => buildCalendarDays(days), [days]);
  const heatmapDays = useMemo(
    () => buildHeatmapDays(calendarDays, mode, priceModel, modelCostDataAvailable),
    [calendarDays, mode, modelCostDataAvailable, priceModel],
  );
  const monthMarkers = useMemo(() => buildMonthMarkers(calendarDays), [calendarDays]);
  const selectedDays = useMemo(
    () => calendarDays.filter((day) => isInRange(day.date, rangeStart, rangeEnd)),
    [calendarDays, rangeEnd, rangeStart],
  );
  const summary = summarizeRange(
    selectedDays,
    rangeStart,
    rangeEnd,
    mode,
    priceModel,
    modelCostDataAvailable,
  );

  useEffect(() => {
    setPriceModel(readStoredQuotaPriceModel());
    const onPriceModel = (event: Event) => {
      const next = (event as CustomEvent<string>).detail;
      if (isOfficialAPIPriceModel(next)) setPriceModel(next);
    };
    window.addEventListener(QUOTA_PRICE_MODEL_EVENT, onPriceModel);
    return () => window.removeEventListener(QUOTA_PRICE_MODEL_EVENT, onPriceModel);
  }, []);

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
        modelCostDataAvailable={modelCostDataAvailable}
        priceModel={priceModel}
        monthMarkers={monthMarkers}
        onDateSelect={chooseDate}
        onDayHover={setHoveredDay}
        hoveredDate={hoveredDay?.date ?? null}
        rangeEnd={rangeEnd}
        rangeStart={rangeStart}
      />

      <div className="range-summary">
        <span>{hoveredDay
          ? hoverSummary(hoveredDay, mode, priceModel, modelCostDataAvailable)
          : summary.hint}</span>
        <strong>
          <em>点两个日期可统计</em>
          {summary.value}
        </strong>
      </div>
    </section>
  );
}
