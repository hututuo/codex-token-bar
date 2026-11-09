import { readFile } from "node:fs/promises";
export const usageFixture = JSON.parse(await readFile(new URL("../../../../Tests/SharedFixtures/recent-chart-usage.json",import.meta.url),"utf8"));
export async function chartFixtureSources(load) {
  const {emptyDashboardSnapshot}=await load("/src/api/fallback/dashboardFallback.ts");
  const codex=emptyDashboardSnapshot();codex.generatedAt=new Date(usageFixture.now*1000).toISOString();
  const breakdown=row=>({inputTokens:row.inputTokens,cachedInputTokens:row.cacheReadTokens??0,outputTokens:row.outputTokens,totalTokens:row.inputTokens+row.outputTokens,calls:row.requests});
  const points=width=>{
    const grouped=new Map();
    for(const row of usageFixture.codex){const key=Math.floor(row.startUnix/width)*width;const rows=grouped.get(key)??[];rows.push(row);grouped.set(key,rows);}
    return [...grouped].sort(([a],[b])=>a-b).map(([startUnix,rows])=>{
      const parts=rows.map(breakdown),sum=key=>parts.reduce((n,row)=>n+row[key],0);
      return {startUnix,label:"",tokens:sum("totalTokens"),calls:sum("calls"),inputTokens:sum("inputTokens"),cachedInputTokens:sum("cachedInputTokens"),outputTokens:sum("outputTokens"),
        cacheHitRate:sum("cachedInputTokens")/sum("inputTokens"),fiveHourRemainingPercent:null,sevenDayRemainingPercent:null,
        modelBreakdowns:rows.map(row=>({model:row.model,eventStartUnix:row.startUnix,breakdown:breakdown(row)}))};
    });
  };
  codex.recentUsage24h=points(300);codex.recentUsage7d=points(3600);codex.recentUsage30d=points(21600);
  const clients={preferences:[],summaries:[],trendBuckets:usageFixture.external,dailyBuckets:[],diagnostics:[],updatedAt:codex.generatedAt};
  return {codex,clients};
}
